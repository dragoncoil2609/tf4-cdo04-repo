# TF4 CDO-04 — Tài liệu hệ thống CDO đầy đủ

> Ngôn ngữ: Tiếng Việt, giữ nguyên thuật ngữ kỹ thuật bằng English.  
> Phạm vi: `tf4-cdo04-repo` tại ngày 2026-07-01.  
> Trạng thái hệ thống: **DEMO PASS** — kiến trúc, IaC, runtime và evidence chính đã hội tụ cho capstone demo; còn caveat nhỏ về k6 zero-drop và một số hardening production.

---

## 0. Executive Summary

TF4 CDO-04 là **SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow** cho 3 dịch vụ tier-1 của fintech demo. Mục tiêu không phải xây dashboard mới, mà biến telemetry thành **prediction decision có audit, fallback, evidence và cost guard**.

Hệ thống nhận telemetry qua `POST /v1/ingest`, expose metrics dạng Prometheus tại `/metrics`, để **ADOT Collector sidecar scrape chính Telemetry API** rồi `remote_write` vào **Amazon Managed Service for Prometheus (AMP)**. Sau đó **EventBridge Scheduler** gửi job mỗi 5 phút vào **SQS**, **Prediction Worker** query AMP lấy cửa sổ 120 phút, align/impute thành 1-minute buckets, gọi **AI Engine** qua **API Gateway HTTP API `AWS_IAM` → VPC Link → same ALB restricted listener `:8443` → AI target group**, ghi audit vào **DynamoDB**, publish alert qua **SNS** khi rủi ro cao. ECS Service Connect giữ làm rollback/fallback trong migration. Khi AI lỗi hoặc data gap lớn, worker fail-open sang **static threshold fallback**.

Design hiện tại chạy tại `us-east-1`, ECS Fargate Linux/x86, private subnets, 1 public ALB reused cho public ingest `:443` và restricted AI listener `:8443`, API Gateway HTTP API với `AWS_IAM`, VPC Link, 1 NAT Gateway, S3/DynamoDB Gateway Endpoints, AMP làm TSDB, DynamoDB làm audit/policy store, S3 làm evidence/failure-buffer/baseline store, CloudWatch làm alarm/dashboard/logs, Budgets + Lambda làm cost breaker.

Điểm cần nhớ: **không có Prometheus server scrape trực tiếp 3 service tier-1**. Đây là kiến trúc **push telemetry → Telemetry API `/metrics` → ADOT scrape → AMP remote_write**. Vì vậy 50 RPS trong k6 là **ingest API headroom**, không phải bằng chứng AMP lưu đủ 50 event samples/second.

---

## 1. System Scope

### 1.1 Tên và angle

- Project: `tf4-cdo04`
- Repo: `tf4-cdo04-repo`
- Angle: **SLO Early-Warning Control Plane with TSDB-backed Prediction Workflow**
- Target users: SRE/Platform/FinOps/AI team trong demo fintech
- Region final: `us-east-1` theo ADR-011
- TSDB final: **Amazon Managed Service for Prometheus (AMP)**, không còn Timestream/InfluxDB

### 1.2 3 dịch vụ tier-1 demo

| Service ID canonical | Pattern | Risk chính | Ghi chú mapping cũ |
|---|---|---|---|
| `payment-gw` | ALB-heavy + RDS-heavy | traffic spike, latency, ALB/API pressure | từng bị gọi `payment-gateway` |
| `ledger` | RDS-heavy / DB connection-heavy | DB exhaustion, query latency | từng bị gọi `ledger-service` |
| `fraud-detector` | Queue-heavy | SQS backlog, worker timeout | từng bị gọi `kyc-worker`/`fraud-detection` |

Service ID canonical cần dùng nhất quán trong telemetry, SQS job, AI request, audit, baseline, test scenario.

### 1.3 SLO / target chính

| Mục tiêu | Target |
|---|---:|
| Prediction cadence | 5 phút |
| Telemetry frequency | 1 phút/metric |
| AI lookback window | 120 phút |
| Lead time | >= 15 phút, target 30 phút |
| False Positive rate | <= 12% |
| Drift catch rate | >= 80% |
| AI API P99 latency | < 500ms |
| AI API throughput | 100 RPS |
| AI API availability | 99.5% |
| Platform cost | <= $200/tháng |

---

## 2. Architecture Tổng Thể

```text
Client / Synthetic telemetry
  |
  | POST /v1/ingest + X-Tenant-Id
  v
Public ALB (:80 hoặc :443 tùy enable_https)
  |
  v
ECS Fargate: telemetry-api (private subnet, port 8080)
  |-- local validation + PII/cardinality guard
  |-- PrometheusExporter.observe()
  |-- /metrics exposes 7 AI signals
  |-- optional S3 failure-buffer on ingest delivery failure
  |
  v
ADOT Collector sidecar scrape localhost:8080/metrics every 15s
  |
  | Prometheus remote_write + SigV4
  v
Amazon Managed Service for Prometheus (AMP)

EventBridge Scheduler, every 5 minutes, 3 service jobs
  |
  v
SQS prediction queue (+ DLQ)
  |
  v
ECS Fargate: prediction-worker (private subnet, outbound only)
  |-- long poll SQS 20s
  |-- query AMP /api/v1/query_range, step=60s, lookback=120m
  |-- align 1-min buckets, forward-fill/zero-fill
  |-- if gap_ratio >= 0.5 => static threshold fallback
  |-- else SigV4 POST /v1/predict to API Gateway execute-api via NAT
  v
API Gateway HTTP API (AWS_IAM)
  |
  | VPC Link
  v
same ALB restricted listener :8443
  |
  v
AI Engine target group -> ECS Fargate: ai-engine (private subnet, port 8080)
  |-- rate limit 600 req/min/tenant
  |-- STL baseline + EWMA control chart
  |-- response: anomaly/severity/recommendation/reasoning/audit_id
  |
  v
prediction-worker
  |-- validate AI response schema
  |-- DynamoDB audit log, TTL 90 days
  |-- SNS alert if anomaly + high severity
  v
CloudWatch Dashboard / CloudWatch Alarms / Cost Guard
```

### 2.1 Evidence model

| Evidence layer | Service | Vai trò |
|---|---|---|
| Metric evidence | AMP | Raw metric/query evidence cho prediction input |
| Visualization evidence | CloudWatch Dashboard | Biểu đồ SRE xem nhanh |
| Decision evidence | DynamoDB Audit Log | Audit record prediction/fallback, `prediction_id`, TTL 90 ngày |
| Failure evidence | S3 evidence bucket | Failure buffer, baseline, eval artifacts nếu dùng |
| Cost evidence | AWS Budgets + Cost Explorer | Budget status, breaker trigger |

---

## 3. Runtime Flow Chi Tiết

## 3.1 Telemetry Ingest Flow

Entrypoint chính:

- App: `src/telemetry_api/main.py`
- Docker command: `uvicorn telemetry_api.main:app --port 8080`
- Public route qua ALB: `POST /v1/ingest`
- Internal metrics route: `GET /metrics`
- Health: `GET /health`

Flow:

```text
Client
  -> POST /v1/ingest
  -> ALB listener rule /v1/ingest
  -> target group port 8080
  -> telemetry-api container
  -> CorrelationIdMiddleware
  -> PayloadSizeLimitMiddleware, max 65536 bytes
  -> parse JSON
  -> require X-Tenant-Id
  -> require fields: ts, tenant_id, service_id, metric_type, value
  -> Pydantic TelemetryPayload validation
  -> tenant header must match body tenant_id
  -> IngestService.ingest()
     -> storage adapter store
     -> PrometheusExporter.observe()
     -> optional AMP delivery retry
     -> optional S3 failure buffer
  -> response 201 accepted / 202 buffered / 503 ingest_failed
```

Validation chính:

- `X-Tenant-Id` bắt buộc, thiếu thì 400.
- `tenant_id` trong body phải match header.
- Timestamp phải RFC3339 UTC strict.
- `value` phải numeric, không boolean, không NaN/Inf.
- Reject internal-only metrics như `error_rate`, `oldest_message_age_seconds`.
- Chỉ accept 7 AI signals.
- Required labels theo metric.
- Reject PII/high-cardinality labels: `email`, `phone`, `name`, `transaction_id`, `account_id`, `card_pan`, `user_id`, `request_id`, `trace_id`, `prediction_id`, raw path có ID.

Telemetry API trong AWS mode:

- `APP_MODE=aws`
- `TELEMETRY_STORAGE_BACKEND=prometheus_amp`
- `AMP_DELIVERY_ENABLED=false`
- Lý do: app không trực tiếp remote_write AMP; **ADOT sidecar** scrape `/metrics` và remote_write.

### 3.2 Scrape / AMP flow

Flow thật hiện tại:

```text
Telemetry API receives pushed telemetry
  -> PrometheusExporter updates in-process gauges
  -> /metrics exposes Prometheus text format
  -> ADOT Collector sidecar scrapes localhost:8080/metrics every 15s
  -> batch processor
  -> prometheusremotewrite exporter
  -> AMP remote_write endpoint
  -> SigV4 auth region us-east-1 service aps
```

Điểm quan trọng:

- Không có Prometheus server scrape các service app trực tiếp.
- Không có scrape target discovery bên ngoài task.
- ADOT scrape **latest gauge snapshot** từ Telemetry API, không lưu mọi event ingest.
- 1-minute prediction bucket vẫn hợp lý vì ADOT scrape 15s/lần, tức khoảng 4 sample/phút nếu producer giữ cadence 1 phút.
- 50 RPS k6 chứng minh ALB + Telemetry API chịu producer traffic; không chứng minh AMP persisted 50 samples/sec.
- ADOT config thực tế nằm inline trong Terraform task definition, không phải `src/telemetry_api/adot-config.yaml`.
- `src/telemetry_api/adot-config.yaml` chỉ là reference và dễ stale.

### 3.3 EventBridge Scheduler → SQS flow

Terraform tạo 3 schedule jobs, mỗi job chạy `rate(5 minutes)`:

```json
{
  "tenant_id": "demo-tenant-001",
  "service_id": "payment-gw|ledger|fraud-detector",
  "lookback_window_minutes": 120,
  "prediction_mode": "balanced"
}
```

Settings:

- Schedule group: `tf4-cdo04-<env>-prediction-schedules`
- Flexible time window: OFF
- Target: SQS prediction queue
- Scheduler DLQ: retention 14 ngày
- IAM role chỉ cần `sqs:SendMessage` vào prediction queue và scheduler DLQ

### 3.4 Prediction Worker flow

Entrypoint:

- App: `src/prediction_worker/app.py`
- Container command: `python app.py`
- Không expose port; outbound only.
- SQS long polling 20 giây.

Flow:

```text
main()
  -> while True
  -> sqs.receive_message(WaitTimeSeconds=20)
  -> for each message: process_job()

process_job()
  -> parse prediction_id, tenant_id, service_id, lookback_window_minutes
  -> require lookback_window_minutes == 120
  -> query_amp_metrics()
     -> 7 sequential PromQL query_range calls
     -> step=60s
     -> start=end-120m
     -> SigV4 auth service aps
  -> align_and_impute()
     -> expected 1-minute timestamps
     -> forward_fill for most signals
     -> zero_fill for queue_depth
     -> max_gap_ratio
  -> evidence_status = complete_window or partial_window
  -> build signal_window payload
  -> if max_gap_ratio >= 0.5: static fallback
  -> else call AI Engine, timeout 2s
  -> validate AI response schema
  -> on AI error/non-200/invalid: static fallback
  -> save audit log to DynamoDB
  -> publish SNS if anomaly and severity high
  -> delete SQS message only on success
```

AI call:

- Endpoint: `http://ai-engine:8080/v1/predict`
- Network: ECS Service Connect DNS
- Timeout: 2s
- Auth intent: SigV4, but current enforcement mismatch noted in stale section.

Fallback trigger:

- AMP query empty.
- `max_gap_ratio >= 0.5`.
- AI timeout.
- AI 5xx.
- AI 429.
- AI unavailable.
- AI invalid response schema.
- Non-200 response.

Audit write:

- DynamoDB table: `tf4-cdo04-audit-<env>`
- PK: `tenant_id`
- SK: `service_time`
- Idempotency via `ConditionExpression: attribute_not_exists(tenant_id) AND attribute_not_exists(service_time)`
- TTL: now + 90 days, field `expires_at_epoch`
- GSI: `prediction-index` on `prediction_status` + `prediction_timestamp`

Alert rule:

- Publish SNS when `anomaly=true` and `severity >= 0.8`, or decision in high-risk actions like `SCALE_UP`, `RETIRE`.

### 3.5 AI Engine flow

Entrypoint:

- App: `src/ai_engine/app/main.py`
- Docker command: `uvicorn app.main:app --host 0.0.0.0 --port 8080`
- Internal route: `POST /v1/predict`
- Health: `/health`
- Exposed only by ECS Service Connect, no public ALB.

Flow:

```text
POST /v1/predict
  -> Rate Limit Middleware
     -> 600 req/min/tenant
     -> 429 + Retry-After: 60 on limit
  -> require X-Tenant-Id
  -> validate tenant_id in datapoints matches header
  -> validate continuity: gap <= 65s
  -> AnomalyDetector.detect_drift()
     -> group by (service_id, metric_type)
     -> load baseline from S3/local
     -> if baseline exists: subtract STL seasonal profile
     -> else: in-window z-score fallback
     -> EWMA control chart
     -> recommend action
  -> confidence gating
     -> confidence < 0.7 => downgrade to INVESTIGATE
  -> AuditLogger.log_decision()
     -> local JSONL or S3 audit
  -> return anomaly/severity/reasoning/recommendation/audit_id
```

Detection method:

- Baseline: STL seasonal profile, 1440 minute-of-day points.
- Residual: `value - seasonal_profile[hour*60 + minute]`.
- EWMA: `alpha=0.3`.
- Control limit: `K=4.0 sigma * sqrt(alpha/(2-alpha))`.
- Breach direction > 0 usually means capacity pressure.
- Breach direction < 0 can mean retire/scale-down/investigate depending metric and below fraction.

Known baseline limitation:

- `fraud-detector.json` has detailed baseline for `cpu_usage_percent` and `memory_usage_percent`.
- Other services/signals may fallback to in-window z-score.
- This affects quality of 7-signal AI behavior.

### 3.6 Self-heal / cost breaker flow

Cost breaker Lambda:

- Trigger: SNS from AWS Budgets at 100% budget threshold.
- Budget cap: `$200/month`.
- Action: scale down `ai-engine` and `prediction-worker` to desiredCount `0`.
- Keeps `telemetry-api` alive so ingest/evidence path remains available.
- Supports `DRY_RUN` env.
- DLQ: `tf4-cdo04-cost-breaker-dlq-<env>`.

This is not application auto-remediation for all anomalies. It is **cost self-protection**. Application recommendations like `SCALE_UP`, `ROLLBACK`, `RETIRE`, `INVESTIGATE` are decision outputs/audit/alerts, not automatic infra mutation except cost breaker.

---

## 4. Contracts Với Team AI

### 4.1 Contract set

| Contract | File | Trách nhiệm CDO | Trách nhiệm AI |
|---|---|---|---|
| Telemetry Contract | `contracts/telemetry-contract.md` | Cung cấp 7 signals, 1-min buckets, PII/cardinality guard, forward/zero-fill | Train/evaluate trên schema đã freeze |
| AI API Contract | `contracts/ai-api-contract.md` | Gọi `POST /v1/predict`, validate response, fallback khi lỗi | Serve API đúng schema/SLA |
| Deployment Contract | `contracts/deployment-contract.md` | Host AI Engine trên ECS Fargate, baseline S3, health check, rollout | Cung cấp image/model behavior đúng contract |

### 4.2 7 AI signals

| Metric | Ý nghĩa | Notes |
|---|---|---|
| `cpu_usage_percent` | CPU pressure | percent |
| `memory_usage_percent` | memory pressure/leak | percent |
| `active_connections` | connection pressure | count |
| `db_connection_pool_pct` | DB pool saturation | percent |
| `queue_depth` | queue backlog | count, zero-fill khi missing |
| `cache_hit_rate_pct` | cache health | percent, drop có thể là risk |
| `api_latency_ms` | API latency | ms |

Frequency: 1 phút/metric. Window: 120 phút. Design ceiling: 50k events/sec peak.

### 4.3 AI API request

Endpoint: `POST /v1/predict`

Request requirements:

- Header `X-Tenant-Id` required.
- `signal_window` array cần >= 120 phút dữ liệu.
- Mỗi datapoint gồm `ts`, `tenant_id`, `service_id`, `metric_type`, `value`, `labels`.
- `context.deployment_version` và `context.time_range` expected.
- Nếu thiếu window hoặc discontinuity lớn: AI có thể trả 400/422; CDO fallback.

### 4.4 AI API response

Response required fields:

```json
{
  "anomaly": true,
  "severity": 0.92,
  "reasoning": "... <= 300 chars ...",
  "recommendation": {
    "action_verb": "SCALE_UP",
    "target": "payment-gw",
    "from_to": "2->4 tasks",
    "confidence": 0.88,
    "evidence_link": "..."
  },
  "audit_id": "uuid"
}
```

Allowed `action_verb`:

- `SCALE_UP`
- `SCALE_DOWN`
- `RETIRE`
- `ROLLBACK`
- `INVESTIGATE`

### 4.5 AI API error handling

| Status | CDO behavior |
|---:|---|
| 400 | invalid input, no retry, fallback |
| 401 | refresh/retry once per contract intent, current code needs review |
| 422 | schema fail, no retry, fallback |
| 429 | backoff 1s -> 2s -> 4s per contract intent; current worker mostly fallback on non-200 |
| 503 | fallback |
| timeout | fallback |
| invalid schema | fallback |

### 4.6 Deployment contract for AI Engine

- ECS Fargate.
- 0.5 vCPU / 1GB memory.
- Desired/min: 2 tasks.
- Max: 4 tasks.
- Port: 8080.
- Health check: `/health`, interval 30s, healthy 2x200, unhealthy 3x non-200.
- Baseline from S3 KMS prefix `baselines/`.
- AI audit retention target: 365 days, KMS encrypted.
- Rollout: ECS rolling deployment + deployment circuit breaker.
- CodeDeploy canary is post-MVP.

Auto rollback trigger per contract intent:

- error rate > 1%
- p99 > 800ms
- capacity exhaustion false deviation > 15%

Current Terraform implements ECS circuit breaker but not full semantic rollback on model quality deviation.

---

## 5. Infrastructure As Code

### 5.1 Terraform backend

- Terraform version: `>= 1.10.0`.
- AWS provider: `>= 5.80.0`.
- Backend: S3 native lockfile.
- Bucket: `tf4-cdo04-terraform-state-0e0bped4`.
- Key default: `tf4-cdo04/sandbox/terraform.tfstate`.
- Region: `us-east-1`.
- Encrypt: true.
- `use_lockfile=true`.
- Supports env: `sandbox`, `staging`, `prod`.

Stale risk: docs/workflow mention `-lock=false` in places. This conflicts with S3 lockfile safety.

### 5.2 Bootstrap

Bootstrap creates:

- S3 state bucket with versioning enabled.
- SSE-S3 encryption.
- Public access block.
- Lifecycle:
  - noncurrent versions -> STANDARD_IA after 30 days
  - expire noncurrent after 180 days
- Bucket policy deny non-TLS (`aws:SecureTransport=false`).
- `prevent_destroy=true`.
- GitHub OIDC provider.
- GitHub deploy role `tf4-cdo04-github-deploy-role`.
- Bounded deploy policy, not AdministratorAccess.
- Developer IAM user `tin` with CloudWatch Logs, APS, S3 evidence access, denied state bucket.

OIDC allowed subjects include main, develop, pull_request, staging/prod environments, optional feature branch subjects.

### 5.3 Networking

VPC:

- CIDR default: `10.0.0.0/16`.
- AZ count default: 2, validation >= 2.
- Public subnets: `10.0.0.0/24`, `10.0.1.0/24` pattern via `cidrsubnet`.
- Private subnets: `10.0.2.0/24`, `10.0.3.0/24` pattern via `cidrsubnet`.
- Internet Gateway: 1.
- NAT Gateway: 1, zonal, in public subnet[0].
- Private route table -> NAT.
- Public route table -> IGW.

VPC Endpoints:

- S3 Gateway Endpoint.
- DynamoDB Gateway Endpoint.
- No Interface Endpoints for ECR, CloudWatch, SSM, Secrets Manager. ECS tasks use NAT for those.

Security Groups:

| SG | Ingress | Egress |
|---|---|---|
| ALB | HTTP 80 and HTTPS 443 from allowed CIDRs/default `0.0.0.0/0` | TCP 8080 to telemetry API SG |
| Telemetry API | TCP 8080 from ALB SG | all outbound |
| Prediction Worker | none | TCP 8080 to AI Engine SG + all outbound |
| AI Engine | TCP 8080 from worker SG | all outbound |

Security note: docs demand strict allowed ingress CIDRs/HTTPS posture; Terraform currently can allow broad public ingress. HTTP/HTTPS behavior depends `enable_https`.

### 5.4 Data module

AMP:

- Workspace alias: `tf4-cdo04-<env>`.
- Used for Prometheus remote_write and query_range.

DynamoDB audit table:

- Name: `tf4-cdo04-audit-<env>`.
- Billing: PAY_PER_REQUEST.
- PK: `tenant_id` (S).
- SK: `service_time` (S).
- GSI: `prediction-index` on `prediction_status` + `prediction_timestamp`.
- TTL: `expires_at_epoch`, enabled.
- PITR: enabled.
- SSE: enabled.

DynamoDB policy table:

- Name: `tf4-cdo04-service-policies-<env>`.
- Billing: PAY_PER_REQUEST.
- PK: `tenant_id` (S).
- SK: `service_name` (S).
- PITR: enabled.
- SSE: enabled.
- Seed policies for `var.prediction_tenant_id`:
  - `ledger` threshold 85.0
  - `payment-gw` threshold 85.0
  - `fraud-detector` threshold 85.0

SQS:

- Prediction queue: `tf4-cdo04-prediction-<env>`.
- SSE enabled.
- Visibility timeout: 180s.
- Retention: 4 days.
- DLQ maxReceiveCount: 5.
- DLQ retention: 14 days.

S3 evidence bucket:

- Name: `tf4-cdo04-evidence-<env>`.
- Versioning enabled.
- SSE-S3 AES256.
- Public access block.
- Bucket policy deny non-TLS.
- Lifecycle:
  - `failure-buffer/` expires after 7 days.
  - all other objects expire after 90 days, current and noncurrent.
- Baseline JSON uploaded from `src/ai_engine/baselines/*.json` to `baselines/`.

KMS/SSM/Secrets:

- KMS alias: `alias/tf4-cdo04-<env>`.
- Rotation enabled.
- Deletion window: 7 days.
- SSM String params:
  - `/<project>/<env>/aws_region`
  - `/<project>/<env>/ai/service_name`
  - `/<project>/<env>/ai/predict_path`
  - `/<project>/<env>/prediction/lookback_window_minutes`
  - `/<project>/<env>/ai/baseline_s3_prefix`
- Secrets Manager, KMS encrypted:
  - `tf4-cdo04/<env>/tenant-ingest-token` — Terraform generates value with `random_password`, stores secret version in Secrets Manager, and exposes sensitive output for k6/default demo workflow. Token is stored in Terraform state by explicit project choice. ECS wires it to Telemetry API through `secrets` as `TENANT_INGEST_TOKEN`; `/v1/ingest` enforces `Authorization: Bearer <token>` when configured.
  - `tf4-cdo04/<env>/slack-webhook-url` — future optional Slack path; MVP uses SNS email.
  - `tf4-cdo04/<env>/ai-sigv4-config` — future AI auth hardening config; Worker -> AI remains IAM SigV4 intent and SYS-09 caveat until verifier exists.

### 5.5 Compute module

Shared:

- ECS Cluster: `tf4-cdo04-<env>-cluster`.
- Container Insights enabled.
- Service Connect namespace: `tf4-cdo04-<env>.local`.
- Launch type: Fargate.
- OS/Arch: Linux/X86_64.
- Network: private subnets, `assignPublicIp=DISABLED`.
- Deployment circuit breaker enabled + rollback.
- ECR repos:
  - `foresight-lens/telemetry_api`
  - `foresight-lens/prediction_worker`
  - `foresight-lens/ai_engine`
- ECR image tag mutability: IMMUTABLE.
- Scan on push: enabled.
- Lifecycle:
  - untagged images > 14 days expire
  - keep max 10 tagged images

Telemetry API ECS task:

| Setting | Value |
|---|---|
| CPU | 512 |
| Memory | 1024 MB |
| Desired | 2 |
| Autoscaling | min 2, max 5 |
| Port | 8080 |
| Containers | `telemetry-api`, `adot-collector` |
| Health check | `curl -f http://localhost:8080/health` |
| Log group | `/ecs/telemetry-api` |
| Log retention | 14 days |
| ALB | yes |
| Service Connect | no server registration |

Telemetry API env:

```text
APP_MODE=aws
AWS_REGION=us-east-1
ENV=<env>
TELEMETRY_STORAGE_BACKEND=prometheus_amp
AMP_DELIVERY_ENABLED=false
AMP_REMOTE_WRITE_ENDPOINT=<amp_remote_write_endpoint>
S3_FAILURE_BUFFER_BUCKET=<evidence_bucket>
S3_FAILURE_BUFFER_PREFIX=failure-buffer/
PREDICTION_QUEUE_URL=<prediction_queue_url>
```

Telemetry API IAM:

- `aps:RemoteWrite`.
- `sqs:SendMessage`.
- `s3:PutObject` to `failure-buffer/*`.

Prediction Worker ECS task:

| Setting | Value |
|---|---|
| CPU | 512 |
| Memory | 1024 MB |
| Desired | 1 |
| Autoscaling | min 1, max 5 |
| Port | none |
| Service Connect | client only |
| Log group | `/ecs/prediction-worker` |
| Log retention | 14 days via `app_log_retention_days` |

Prediction Worker env:

```text
AWS_REGION=us-east-1
SQS_QUEUE_URL=<prediction_queue_url>
AMP_QUERY_ENDPOINT=<amp_query_endpoint>
DYNAMODB_AUDIT_TABLE=<audit_table>
DYNAMODB_POLICY_TABLE=<policy_table>
AI_ENGINE_ENDPOINT=http://ai-engine:8080/v1/predict
AI_TIMEOUT_SECONDS=2
ALERT_TOPIC_ARN=<sns_topic>
```

Prediction Worker IAM:

- `sqs:ReceiveMessage`
- `sqs:DeleteMessage`
- `sqs:ChangeMessageVisibility`
- `aps:QueryMetrics`
- `aps:GetLabels`
- `aps:GetMetricMetadata`
- `aps:GetSeries`
- `dynamodb:PutItem` audit
- `dynamodb:GetItem` policy
- `sns:Publish`

AI Engine ECS task:

| Setting | Value |
|---|---|
| CPU | 512 |
| Memory | 1024 MB |
| Desired | 2 |
| Autoscaling | min 2, max 4 |
| Port | 8080 |
| Service Connect | server, `discovery_name=ai-engine` |
| Health check | `/health` via Python urllib |
| Log group | `/ecs/ai-engine` |
| Log retention | 14 days via `app_log_retention_days` |

AI Engine env:

```text
AWS_REGION=us-east-1
PORT=8080
BASELINE_BACKEND=s3
BASELINE_S3_BUCKET=<evidence_bucket>
BASELINE_S3_PREFIX=baselines/
EVIDENCE_BUCKET_NAME=<evidence_bucket>
```

AI Engine IAM:

- `s3:ListBucket`
- `s3:GetObject` baseline/evidence
- `ssm:GetParameter`
- `secretsmanager:GetSecretValue`
- `kms:Decrypt`
- `cloudwatch:PutMetricData`

### 5.6 ALB

- Type: application.
- Scheme: internet-facing.
- Target type: IP.
- Target group port: 8080.
- Health check path: `/health`.
- Deregistration delay: 30s.
- ACM certificate DNS validation for `var.domain_name`, default `xbrain26hackathon269.software`.
- HTTP listener port 80:
  - if `enable_https=true`: redirect to HTTPS
  - else: default 404
- HTTPS listener port 443 optional:
  - TLS policy: `ELBSecurityPolicy-TLS13-1-2-2021-06`
  - default 404
- Listener rule priority 10:
  - forward `/health`
  - forward `/v1/ingest`

Mismatch note: some docs require HTTPS/TLS as final posture, but sandbox/current Terraform may still expose HTTP behavior depending var and certificate.

### 5.7 Autoscaling

| Service | Min | Max | Target tracking | Step scaling |
|---|---:|---:|---|---|
| Telemetry API | 2 | 5 | CPU 70%, Memory 75% | ALB p99 scale-out +1, cooldown 300s |
| Prediction Worker | 1 | 5 | none | SQS queue age/visible scale-out +1, idle scale-in -1, cooldown 120s |
| AI Engine | 2 | 4 | CPU 70% | Service Connect p95/p99 latency scale-out +1, cooldown 300s |

---

## 6. Observability

### 6.1 CloudWatch log groups

| Log group | Retention | Encryption | Purpose |
|---|---:|---|---|
| `/ecs/telemetry-api` | 14 days | default | app + ADOT logs |
| `/ecs/prediction-worker` | 14 days | default | worker logs |
| `/ecs/ai-engine` | 14 days | default | AI API logs |
| `/ecs/<project>-<env>-ai-engine-audit` | 365 days | KMS | AI audit logs |
| `/aws/lambda/<project>-cost-breaker-<env>` | 14 days | default | cost breaker logs |

### 6.2 Telemetry API alarms

| Alarm | Threshold | Period/eval | Actions |
|---|---:|---|---|
| CPU high | > 70% | 2 x 300s | SNS operational |
| Memory high | > 75% | 2 x 300s | SNS operational |
| ALB p99 TargetResponseTime | > 0.8s | 5 x 60s | SNS + scale-out |
| ALB 5xx rate | > 1% | 5 x 60s | SNS |
| RunningTaskCount low | < 2 | 3 x 60s, missing=breaching | SNS |
| Budget-style CPU high | >= 85% | 1 x 60s | budget SNS |
| Budget-style Memory high | >= 85% | 1 x 60s | budget SNS |

### 6.3 Prediction Worker / SQS alarms

| Alarm | Threshold | Period/eval | Actions |
|---|---:|---|---|
| Queue oldest message age | > 120s | 2 x 60s | SNS + scale-out |
| Queue visible messages | > 20 | 5 x 60s | SNS + scale-out |
| Queue idle | <= 0 | 2 x 300s | scale-in only |
| DLQ visible | > 0 | 1 x 300s | SNS |
| Worker RunningTaskCount low | < 1 | 3 x 60s | SNS |
| Worker CPU high | >= 85% | 1 x 60s | budget SNS |
| Worker Memory high | >= 85% | 1 x 60s | budget SNS |

### 6.4 AI Engine alarms

| Alarm | Threshold | Period/eval | Actions |
|---|---:|---|---|
| CPU high | > 70% | 2 x 300s | SNS |
| Memory high | > 75% | 2 x 300s | warning only, no alarm_actions |
| Service Connect RequestCount | > 5000 | 3 x 60s | SNS |
| Service Connect HTTP 5xx count | > 0 | 3 x 60s | SNS |
| Service Connect 5xx rate | > 1% | 3 x 60s | SNS |
| Service Connect p95 latency | > 350ms | 3 x 60s | SNS + scale-out |
| Service Connect p99 latency | > 500ms | 3 x 60s | SNS + scale-out |
| RunningTaskCount low | < 2 | 3 x 60s | SNS |
| Budget-style CPU high | >= 85% | 1 x 60s | budget SNS |
| Budget-style Memory high | >= 85% | 1 x 60s | budget SNS |

### 6.5 Dashboard

CloudWatch dashboard contains cost/operational widgets and SRE guidance. It is visualization evidence, not source of truth for prediction. Source of truth for metric input remains AMP and source of truth for decision remains DynamoDB audit.

### 6.6 Budget alarms and cost breaker

Budget:

- Limit: `$200/month`.
- Notifications: 50%, 80%, 100% actual cost.

Policy:

| Threshold | Budget | Action |
|---|---:|---|
| 50% | $100 | Alert only |
| 80% | $160 | Manual review, freeze cadence, reduce logs/synthetic load |
| 100% | $200 | Scale down `prediction-worker` + `ai-engine` to 0; keep `telemetry-api` |

Lambda breaker:

- Runtime: Python 3.10.
- Trigger: SNS budget notification.
- Scales ECS services with `ecs:UpdateService`.
- Publishes SNS result.
- Uses DLQ.
- `DRY_RUN=true` for test.

---

## 7. Security Posture

### 7.1 Network security

- ECS tasks run in private subnets.
- `assignPublicIp=DISABLED`.
- Only ALB is public.
- Worker has no inbound listener.
- AI Engine only reachable from worker SG through Service Connect/port 8080.
- S3/DynamoDB access can avoid NAT through Gateway Endpoints.
- ECR/CloudWatch/SSM/Secrets traffic still uses NAT because Interface Endpoints not provisioned.

### 7.2 IAM

Good:

- GitHub OIDC uses dedicated deploy role, not static long-lived AWS key.
- ECS task roles split by service.
- Telemetry task gets remote write, SQS send, S3 failure-buffer put; ECS execution role reads only tenant ingest token secret and decrypts it through project KMS for task-start injection.
- Worker task gets SQS consume, APS query, DynamoDB audit/policy, SNS publish; no Secrets Manager runtime dependency in current MVP.
- AI task gets baseline/evidence read, SSM/Secrets/KMS, metrics publish; AI SigV4 app-side enforcement remains production hardening.

Risks:

- Some GitHub deploy policy statements still broad: `ssm:*`, `cloudwatch:*`, `sns:*` on `*` for untagged service access.
- `PassRole` bounded by service but still needs periodic review.
- Some resources may not support tag-on-create, causing tag-conditioned policy edge cases.

### 7.3 Data protection

- S3 state bucket encrypted and blocks public access.
- S3 evidence bucket encrypted and blocks public access.
- DynamoDB SSE enabled.
- KMS key exists for AI/audit/secrets related flows.
- Secrets Manager values are not managed in Terraform state; ECS injects the tenant ingest token by ARN through task definition `secrets`.
- PII denylist and high-cardinality rejection at telemetry boundary.

### 7.4 AI auth mismatch

Contract says IAM SigV4. Worker sends SigV4-style auth intent, but AI Engine app itself does not enforce SigV4. App requires `X-Tenant-Id`; comments suggest SigV4 enforced at edge, yet there is no API Gateway/ALB auth enforcement in described runtime path. This is a P0 contract drift until explicitly resolved.

---

## 8. Testing & Acceptance

### 8.1 Final evidence command set

Final evidence was collected with direct focused commands, not full all-in-one matrix runner:

```bash
export TENANT_INGEST_TOKEN="$(terraform -chdir=infra/terraform output -raw tenant_ingest_token)"

k6 run tests/k6/acceptance_ingest.js \
  -e TELEMETRY_API_HOST=https://xbrain26hackathon269.software \
  -e TENANT_ID=demo-tenant-001 \
  -e SERVICE_IDS=ledger,payment-gw,fraud-detector \
  -e TENANT_INGEST_TOKEN="$TENANT_INGEST_TOKEN" \
  -e RATE=50 \
  -e DURATION=3h \
  --summary-export evidence/logs/acceptance-50rps-3h-final-summary.json
```

Worker, AI Engine and audit evidence were collected from CloudWatch Logs and DynamoDB into `evidence/logs/`.

`tests/e2e/run_final_acceptance.sh` remains the broader reusable entrypoint, but final demo evidence here is the focused 2m/3h load + audit/worker/AI evidence pack.

### 8.2 Acceptance gates

| Gate | Command/tool | Evidence output |
|---|---|---|
| Unit + contract | `PYTHONPATH=src/ai_engine:src pytest -q` | pytest output |
| Deploy smoke | `bash scripts/post_apply_smoke.sh` | `final-smoke.log` |
| AI complete path | `bash tests/e2e/tf4_scenario_matrix.sh` | `tf4-scenario-audit-scan.json` |
| 4 TF4 scenarios | `bash tests/e2e/tf4_scenario_matrix.sh` | `tf4-scenario-summary.json` |
| Eval metrics | `python tests/e2e/eval_report.py` | `eval-report.json`, `eval-report.md` |
| Load 50 RPS | `k6 run tests/k6/acceptance_ingest.js` | `acceptance-50rps-2m-final-summary.json`, `acceptance-50rps-3h-final-summary.json` |
| Security probes | `bash tests/e2e/security_probes.sh` | `security-probes.json` |
| Cost guard | Budget + Cost Explorer | `budget-final.json`, `cost-explorer-final.json` |

### 8.3 Hard pass rules

Required audit fields:

```text
prediction_source = AI_ENGINE
evidence_status = complete_window
ai_status_code = 200
```

Additional pass criteria:

- 4 scenarios pass.
- >= 3 services covered.
- Recall >= 80%.
- False Positive <= 12%.
- F1/confusion/Brier reported.
- >= 1 scenario lead time >= 15min.
- k6 50 RPS accepted: p95 < 1000ms, error rate < 1%, sustained ~50 RPS.
- 3h k6 caveat visible: 5 dropped iterations and 1 failed request over 539,995 requests; owner accepted as operational pass.
- Security probes/tests cover tenant mismatch and `/metrics` exposure.
- DLQ no growth.
- Budget < $200 by sizing model and budget/cost-breaker configuration.

### 8.4 Four mentor-facing scenarios

| Scenario | Service | Expected | Script |
|---|---|---|---|
| Gradual drift | `ledger` | anomaly | `tests/e2e/tf4_scenario_matrix.sh` |
| Sudden spike | `payment-gw` | anomaly | `tests/e2e/tf4_scenario_matrix.sh` |
| Slow leak | `fraud-detector` | anomaly | `tests/e2e/tf4_scenario_matrix.sh` |
| Noisy baseline | `fraud-detector` | no anomaly / low severity | `tests/e2e/tf4_scenario_matrix.sh` |

### 8.5 Unit test map

| Area | Test file | Coverage |
|---|---|---|
| AI API | `src/ai_engine/tests/test_api.py` | health, happy path, spike, leak, drop, auth, schema, tenant mismatch, gap |
| Telemetry ingest | `src/telemetry_api/tests/telemetry_api/test_ingest_api.py` | payload/schema/tenant/PII/cardinality/required labels |
| Prometheus metrics | `src/telemetry_api/tests/telemetry_api/test_prometheus_metrics.py` | `/metrics`, 7 signals, safe labels |
| Local storage | `src/telemetry_api/tests/telemetry_api/test_local_jsonl_adapter.py` | JSONL write |
| Idempotency | `src/telemetry_api/tests/telemetry_api/test_idempotency.py` | same payload, label order, different payloads |
| S3 buffer/retry | `src/telemetry_api/tests/telemetry_api/test_s3_failure_buffer.py` | AMP retry, S3 buffer, non-transient, replay |
| Worker | `src/prediction_worker/tests/test_prediction_worker.py` | align/impute, fallback, audit, process_job, AI errors |
| Cost breaker | `tests/test_cost_breaker.py` | 50/80 skip, 100 scale-down, dry-run, malformed input |

### 8.6 E2E and smoke

`tests/e2e/acceptance_ai_pipeline.sh`:

- Seeds 125 minutes x 7 signals.
- Sends SQS prediction job.
- Polls DynamoDB audit.
- Verifies complete window + AI_ENGINE + 200.

`scripts/post_apply_smoke.sh`:

- Wait ECS services stable.
- Health check `/health`.
- Ingest smoke `/v1/ingest`, expect 201/202.
- Verify `/metrics` not public, expect 404/403.
- Optional AMP query endpoint check.
- ECS service state active/running desired.
- SQS queue depth below max.
- DLQ not growing.
- ADOT error log check.
- Policy table fallback warning check.

### 8.7 Test evidence status

Final live evidence has been regenerated under `evidence/logs/` and summarized in `docs/07_test_eval_report.md`.

Current demo acceptance status:

```text
2m 50 RPS smoke: PASS, 6,001 requests, 0 failures, 0 dropped iterations.
3h 50 RPS run: accepted PASS with caveat, 539,995 requests, p95 257 ms, 1 failed request, 5 dropped iterations.
Worker/AI path: PASS, DynamoDB audit contains AI_ENGINE + complete_window + ai_status_code=200 for ledger, payment-gw, fraud-detector.
```

Caveat: 3h k6 is not a strict zero-drop pass. It is accepted as operational pass because drop rate was ~0.00093% and request success was 99.9998%.

---

## 9. CI/CD

Workflow: `.github/workflows/deploy.yml`

Jobs:

1. `lint-and-validate`
   - Markdown check.
   - `terraform fmt -check`.
   - `terraform validate`.
   - Python pytest.
2. `security-scan`
   - Gitleaks.
3. `build-and-push`
   - Matrix: telemetry_api, prediction_worker, ai_engine.
   - Docker build.
   - Trivy scan, CRITICAL gate.
   - Push to ECR with SHA tag.
4. `terraform-deploy`
   - Terraform init.
   - Plan.
   - Apply.
   - Post-apply smoke test.

Environment mapping:

- `main` -> prod.
- `develop` -> staging.

Known CI/CD risks:

- Python version in workflow appears as `3.14`, likely typo/pre-release mismatch.
- Some docs/QA note `terraform apply -auto-approve` and smoke as fake/echo in older state; verify actual workflow before trusting.
- `-lock=false` mentioned in docs is unsafe if still used.
- OIDC trust and deploy policy should stay bounded.

---

## 10. Config Inventory

### 10.1 Telemetry API env

```text
APP_MODE=aws
AWS_REGION=us-east-1
ENV=<env>
PORT=8080
TELEMETRY_STORAGE_BACKEND=prometheus_amp
AMP_DELIVERY_ENABLED=false
AMP_REMOTE_WRITE_ENDPOINT=<amp_remote_write_endpoint>
S3_FAILURE_BUFFER_BUCKET=<evidence_bucket>
S3_FAILURE_BUFFER_PREFIX=failure-buffer/
PREDICTION_QUEUE_URL=<prediction_queue_url>
```

Defaults in app settings:

| Setting | Default |
|---|---|
| `max_ingest_payload_bytes` | 65536 |
| `telemetry_storage_backend` | `local_jsonl` local / `prometheus_amp` aws |
| `amp_delivery_max_retries` | 3 |
| `amp_delivery_retry_base_delay_ms` | 500 |
| `s3_failure_buffer_enabled` | true |
| `port` | code default 8000, runtime 8080 |

### 10.2 Prediction Worker env

```text
AWS_REGION=us-east-1
SQS_QUEUE_URL=<prediction_queue_url>
AMP_QUERY_ENDPOINT=<amp_query_endpoint>
DYNAMODB_AUDIT_TABLE=<audit_table>
DYNAMODB_POLICY_TABLE=<policy_table>
AI_ENGINE_ENDPOINT=http://ai-engine:8080/v1/predict
AI_TIMEOUT_SECONDS=2
ALERT_TOPIC_ARN=<sns_topic>
```

Code default caveat:

- Default fallback endpoint in code uses `http://ai-engine.cdo-services/v1/predict`, but Terraform overrides with `http://ai-engine:8080/v1/predict`. Runtime OK, default stale.

### 10.3 AI Engine env

```text
AWS_REGION=us-east-1
PORT=8080
BASELINE_BACKEND=s3
BASELINE_S3_BUCKET=<evidence_bucket>
BASELINE_S3_PREFIX=baselines/
EVIDENCE_BUCKET_NAME=<evidence_bucket>
```

### 10.4 Cost Breaker env

```text
CLUSTER_NAME=<ecs_cluster>
SERVICE_NAME=<ai_engine_service>
WORKER_SERVICE_NAME=<prediction_worker_service>
SNS_TOPIC_ARN=<budget_topic>
DRY_RUN=false
```

---

## 11. Stale Docs, Contract Drift, Unused/Suspect Files

### 11.1 P0/P1 mismatches

| ID | Area | Drift | Impact | Fix direction |
|---|---|---|---|---|
| SYS-01 | Edge security | Docs require HTTPS/TLS, Terraform can run HTTP/sandbox and ALB HTTP behavior varies by `enable_https` | Public posture mismatch | Make HTTPS final explicit; sandbox exception documented; enforce redirect when cert ready |
| SYS-02 | Ingress CIDR | ALB CIDR can be `0.0.0.0/0`, docs want explicit allowed CIDRs | Accidental public exposure | Require `allowed_ingress_cidrs` var per env |
| SYS-03 | Terraform backend | Docs/workflow mention `-lock=false`, backend supports lockfile | State race risk | Remove `-lock=false`, document S3 lockfile |
| SYS-05 | CI/CD | QA notes auto-approve and weak smoke in older flow | False green deploy | Gate apply with real smoke/evidence |
| SYS-08 | AI runtime | Previous QA suspected placeholder AI runtime | Live audit now proves `AI_ENGINE` + `complete_window` + `ai_status_code=200` | Resolved for demo evidence; keep verifying image provenance in CI |
| SYS-09 | AI auth | Worker SigV4/service mismatch; AI app does not enforce SigV4 | Auth contract not enforced at app layer | Add enforceable auth layer or update contract truthfully |
| SYS-11 | AMP ingestion | App AMP adapter/stub vs ADOT remote_write docs | Confusion over actual data path | Document ADOT as only AWS remote_write path; rename no-op adapter |
| SYS-12 | k6 path | Some stale docs/scripts may still call `/v1/telemetry`; current route is `/v1/ingest` | Operator confusion | Keep final tests on `/v1/ingest`; archive old scripts if found |
| SYS-13 | Test report | Previously draft/placeholder | Final evidence now summarized in `docs/07_test_eval_report.md` | Resolved for demo; caveat remains for 3h k6 zero-drop |
| SYS-15 | Terraform README | README vars mention old vars/Timestream/Singapore | Operator error | Rewrite README from current root variables |

### 11.2 Stale/unused/suspect files

| File | Issue | Recommendation |
|---|---|---|
| `docs/00_client_debrief.md.md` | Double `.md.md`; references may point to missing `docs/00_client_debrief.md` | Rename or fix references |
| `src/telemetry_api/app.py` | Old Telemetry API with `/v1/telemetry`; Docker uses `telemetry_api.main:app` | Delete or mark `DEPRECATED` |
| `src/telemetry_api/adapters/amp_adapter_stub.py` | No-op storage adapter named like real AMP adapter | Rename/comment as `AmpNoopStorageAdapter` |
| `src/telemetry_api/adot-config.yaml` | Reference only; runtime ADOT config inline in Terraform | Delete or add CI drift check |
| `infra/terraform/ai-service.json` | AWS describe-services snapshot with real ARNs/subnets | Move to evidence or delete |
| `infra/terraform/ai-service-connect.json` | Snapshot, not Terraform input | Move/delete |
| `infra/terraform/worker-service-connect.json` | Snapshot, not Terraform input | Move/delete |
| `infra/terraform/baseline-demo.json` | Demo payload in Terraform dir | Move to tests/evidence |
| `note/*.json` IAM/budget/state policies | Reference policies likely migrated into Terraform | Archive/delete after verify |
| `tests/__pycache__/test_basic.cpython-314-pytest-9.1.1.pyc` | Python cache without source | Delete |
| `tests/test_basic.py` if present | `assert True` placeholder per docs agent | Delete/replace |
| Old `tests/k6/sc01_*`–`sc04_*` scripts | Diagnostic-only high-RPS scripts, not final acceptance evidence | Deleted; scenario coverage is `tests/e2e/tf4_scenario_matrix.sh` |
| `infra/terraform/README.md` | Variables and service choices stale | Rewrite |
| `infra/terraform/modules/observability/cost_dashboard.tf` | Text may mention Timestream after AMP migration | Update labels |
| `contracts/telemetry-contract.md` | Mentions Timestream/Managed Prometheus alternatives and old cost model | Add final AMP addendum inline |
| `src/telemetry_api/Dockerfile` | Copies whole folder, likely includes tests/cache/docs without `.dockerignore` | Add `.dockerignore` |
| `pytest.ini` | `testpaths=tests` may omit tests under `src/*/tests` | Include all test dirs |

### 11.3 Contradiction themes

- **Route drift**: `/v1/telemetry` old vs `/v1/ingest` current.
- **Metrics backend drift**: Timestream/InfluxDB old vs AMP current.
- **Region drift**: `ap-southeast-1` old vs `us-east-1` current.
- **Deployment strategy drift**: CodeDeploy/canary old vs ECS rolling + circuit breaker current.
- **AI runtime drift**: previously suspected placeholder/mocked smoke; final audit evidence now proves real AI path for demo.
- **Auth drift**: SigV4 contract vs no app-level enforcement.
- **Test evidence drift**: draft reports vs actual pass artifacts missing.

---

## 12. Operational Runbooks

### 12.1 Normal deploy check

1. Terraform apply with lock enabled.
2. ECS services stable:
   - telemetry-api desired/running 2.
   - prediction-worker desired/running 1.
   - ai-engine desired/running 2.
3. ALB `/health` returns success.
4. `/v1/ingest` returns 201/202 for valid payload.
5. `/metrics` is not public through ALB.
6. ADOT has no remote_write errors in logs.
7. AMP query returns recent samples.
8. EventBridge schedules enabled.
9. SQS prediction queue no backlog after a few cycles.
10. DynamoDB audit gets records with `prediction_source=AI_ENGINE` for complete cases.
11. DLQs zero growth.

### 12.2 AI failure mode

Expected behavior:

- Worker times out/non-200/invalid response.
- Worker does not crash.
- Worker writes audit record with `prediction_source=static_threshold_fallback`.
- `fallback_reason` records exact reason.
- SNS alert may still fire if static threshold indicates high risk.

Operator checks:

- AI Engine ECS health.
- Service Connect 5xx/p95/p99 alarms.
- Worker logs for `ai_timeout`, `ai_5xx`, `ai_429`, `ai_invalid_response`.
- DynamoDB audit source distribution.

### 12.3 AMP/data gap failure mode

Expected behavior:

- AMP query missing data or gap ratio >= 0.5.
- Worker skips AI call.
- Worker uses static threshold fallback.
- Audit evidence status becomes `partial_window`.

Operator checks:

- ADOT logs.
- AMP active series.
- `/metrics` output from Telemetry API task.
- Ingest API acceptance rate.
- Failure buffer S3 prefix.

### 12.4 Cost guard runbook

50% budget:

- Check synthetic load schedule.
- Check CloudWatch log volume.
- Check AMP active series/cardinality.
- No automatic scale-down.

80% budget:

- Freeze cadence at 5 minutes.
- Reduce synthetic load.
- Reduce log verbosity.
- Review PromQL scoping.
- Manual review before more load.

100% budget:

- Cost breaker scales `ai-engine` and `prediction-worker` to 0.
- `telemetry-api` remains up.
- Confirm SNS notification.
- Confirm ECS desired counts.
- Confirm breaker DLQ no messages.

Rollback after breaker:

```bash
aws ecs update-service --cluster <cluster> --service <ai-engine-service> --desired-count 2
aws ecs update-service --cluster <cluster> --service <prediction-worker-service> --desired-count 1
```

Use `DRY_RUN=true` for breaker test.

---

## 13. Current Readiness Assessment

### 13.1 What is strong

- Architecture direction is clear and documented.
- ADRs cover major decisions through AMP/us-east-1/x86/ADOT sidecar.
- Terraform modules are cleanly separated: networking, data, compute, observability.
- ECS services use private subnets and Service Connect.
- Failure modes have fallback and audit path.
- Cost cap has explicit 50/80/100 policy and breaker.
- Contracts with AI team are mostly explicit.
- Unit test coverage exists across telemetry, worker, AI, cost breaker.
- Final live evidence now shows 3-service ingest, AMP/Worker/AI path and audit records.
- 3h 50 RPS run sustained target load over custom HTTPS domain with p95 257 ms.

### 13.2 Remaining caveats before production-like claim

- 3h k6 had 5 dropped iterations and 1 failed request; accepted for demo, but not strict zero-drop.
- AI SigV4 contract is not enforceable in current internal app path.
- 100 RPS acceptance was not rerun in final evidence pack.
- Cross-account tenant isolation remains N/A in single sandbox.
- Cost Explorer same-day actuals lag; use budget/cost-breaker + sizing model as proof.
- CI/CD safety still needs periodic verification: lock enabled, smoke real, no fake pass.
- Stale archive docs may still mention Timestream, Singapore, `/v1/telemetry`, or old service IDs.

### 13.3 Priority fix order

1. Keep final evidence pack committed and clearly label 3h k6 caveat.
2. Fix CI smoke to use custom domain `ALB_BASE_URL=https://xbrain26hackathon269.software`.
3. Resolve AI auth truth: enforce SigV4 somewhere real, or update contract.
4. Optional: rerun k6 3h with bigger VU pool if a strict zero-drop artifact is required.
5. Optional: run 100 RPS 10m acceptance if mentor asks for 100 RPS proof.
6. Delete/move stale snapshots and cache files.
7. Rewrite Terraform README from current variables.
8. Expand/refresh baselines for all 7 signals and 3 services if AI quality target is strict.

---

## 14. Source-of-truth Rules

Use this priority when docs conflict:

1. Runtime code and Terraform currently deployed path.
2. Frozen contracts, if implementation is expected to conform.
3. ADR-011/ADR-012 for final platform decisions.
4. Current tests/scripts only if they use `/v1/ingest` and current env names.
5. Older docs mentioning Timestream, InfluxDB, Singapore, `/v1/telemetry`, CodeDeploy canary are stale unless explicitly marked archive.

---

## 15. Minimal glossary

| Term | Meaning in this repo |
|---|---|
| AMP | Amazon Managed Service for Prometheus, final TSDB |
| ADOT | AWS Distro for OpenTelemetry Collector sidecar in telemetry-api task |
| AI Engine | ECS service serving `/v1/predict` over Service Connect |
| Prediction Worker | SQS consumer querying AMP and calling AI Engine |
| Static threshold fallback | Fail-open decision path when AI/data unavailable |
| Evidence status | `complete_window` or `partial_window` in audit |
| Service Connect | Internal ECS DNS/routing for worker -> AI Engine |
| Cost breaker | Lambda scaling AI/worker to 0 when monthly cost hits 100% budget |
| Tier-1 services | `payment-gw`, `ledger`, `fraud-detector` |

---

## 16. Final state statement

Hệ thống CDO-04 hiện là **DEMO PASS with documented caveats**. Control plane pieces exist and live evidence proves the core path: custom HTTPS ingest, ADOT-to-AMP telemetry, scheduled Worker jobs, AI Engine calls, DynamoDB audit records, SNS alert path and 3-service coverage.

Status nên trình bày là:

```text
DEMO PASS — architecture and runtime evidence converged for capstone review.
Caveats: 3h k6 not strict zero-drop, AI SigV4 enforcement remains production hardening, Cost Explorer actuals are delayed supporting evidence.
```
