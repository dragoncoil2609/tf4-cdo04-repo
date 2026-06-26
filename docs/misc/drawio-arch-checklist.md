# Draw.io Architecture Checklist - CDO-04 Infra Design

> Mục tiêu: checklist nhanh để vẽ diagram hiện tại của `02_infra_design.md`: `us-east-1`, ECS Fargate Linux/x86, AMP, public ingest ALB, ECS Service Connect cho Worker → AI, DynamoDB audit, SQS orchestration và cost-optimized NAT + Gateway Endpoints.

## 1. Setup canvas

- [ ] Dùng AWS official icon set trong draw.io / diagrams.net.
- [ ] Title: **TF4 CDO-04 SLO Early-Warning Control Plane - us-east-1**.
- [ ] Ghi caption tổng ở góc dưới: **Public telemetry ingest, private prediction workflow, AMP metric evidence, DynamoDB audit, fallback-safe AI call path.**
- [ ] Dùng màu/legend nhất quán:
  - External actors: xám.
  - Public subnet/resources: xanh dương nhạt.
  - Private ECS/app subnets: xanh lá nhạt.
  - Managed AWS services: tím/neutral.
  - Security/data boundary: nét đứt.
  - Critical hot path: mũi tên đậm.

## 2. Boundaries cần vẽ

- [ ] **External / Client boundary**: nằm ngoài AWS account.
  - `payment-gateway`
  - `ledger-service`
  - `kyc-worker`
  - `k6 / Locust synthetic load`
- [ ] **AWS Account boundary**: bao quanh toàn bộ tài nguyên AWS.
- [ ] **Region boundary**: `us-east-1`.
- [ ] **VPC boundary**: `tf4-cdo04-vpc`.
- [ ] **AZ boundary**: vẽ 2 AZ để thể hiện multi-AZ private subnets.
- [ ] **Public subnet boundary**:
  - Public ALB
  - NAT Gateway
- [ ] **Private app subnet boundary**:
  - ECS Cluster
  - Telemetry API service
  - Prediction Worker service
  - AI Engine service
  - ADOT/Prometheus Agent hoặc app remote_write component
  - ECS Service Connect namespace/proxy path
- [ ] **Managed services outside VPC / regional services boundary**:
  - AMP workspace
  - EventBridge Scheduler
  - SQS + DLQ
  - DynamoDB audit/policy
  - S3 evidence/failure buffer/baseline
  - Secrets Manager / SSM
  - CloudWatch Logs/Metrics/Dashboard/Alarms
  - SNS alert topic
  - ECR
  - KMS
- [ ] **Trust boundaries**:
  - Internet → Public ALB
  - Public ALB → Private ECS tasks
  - ECS task roles → AWS managed APIs
  - Worker → AI Engine private Service Connect path
  - Tenant data isolation boundary by `tenant_id` + `service_id`

## 3. Resources cần có trên diagram

### External producers

- [ ] `payment-gateway` mock service.
- [ ] `ledger-service` mock service.
- [ ] `kyc-worker` mock service.
- [ ] `k6 / Locust` test runner.

### Networking

- [ ] VPC in `us-east-1`.
- [ ] 2 public subnets.
- [ ] 2 private app subnets.
- [ ] Internet Gateway.
- [ ] **1 public Application Load Balancer** for `/v1/ingest` only.
- [ ] 1 zonal NAT Gateway for outbound AWS API traffic not using Gateway Endpoints.
- [ ] S3 Gateway VPC Endpoint.
- [ ] DynamoDB Gateway VPC Endpoint.
- [ ] Optional hardening note, not baseline: AMP `aps-workspaces` Interface Endpoint.

### Compute / ECS

- [ ] ECS Cluster: `tf4-cdo04-cluster`.
- [ ] ECS Fargate service: `telemetry-api`, 2 tasks, private subnet, no public IP.
- [ ] ECS Fargate service: `prediction-worker`, 1 task baseline, private subnet, no public IP.
- [ ] ECS Fargate service: `ai-engine`, 2 tasks baseline / max 4, private subnet, no public IP, port 8080.
- [ ] ECS Service Connect namespace/service for AI path, label it `ai-engine:8080`.
- [ ] ADOT Collector / Prometheus Agent / app remote_write component near Telemetry API.

### Data and messaging

- [ ] Amazon Managed Service for Prometheus workspace: `tf4-cdo04-telemetry`.
- [ ] EventBridge Scheduler: 5-minute cadence.
- [ ] SQS queue: `prediction-jobs`.
- [ ] SQS DLQ: `prediction-jobs-dlq`.
- [ ] DynamoDB table: audit + service policy.
- [ ] S3 bucket/prefixes:
  - `baselines/`
  - `evidence/`
  - `failure-buffer/`

### Security/config/observability

- [ ] Secrets Manager / SSM:
  - AI Service Connect base URL/service name
  - webhook secret
  - tenant ingest token
- [ ] KMS key(s) for S3/DynamoDB/SQS/Logs/Secrets where applicable.
- [ ] CloudWatch Logs for ECS services.
- [ ] CloudWatch Dashboard and Alarms.
- [ ] SNS topic for high-risk/cost/failure alerts.
- [ ] ECR repositories for container images.
- [ ] IAM roles:
  - ECS task execution role
  - Telemetry/collector task role with `aps:RemoteWrite`
  - Prediction Worker task role with SQS, `aps:QueryMetrics`, DynamoDB, SNS, S3, Secrets access
  - AI Engine task role with S3 baseline + logs/config access
  - EventBridge Scheduler execution role with `sqs:SendMessage`

## 4. Luồng chính A → B cần vẽ và caption ngắn

### Flow 1 - Telemetry ingest

- [ ] `payment-gateway / ledger-service / kyc-worker / k6` → Public ALB `/v1/ingest`.
  - Caption: **HTTPS telemetry ingest with tenant header.**
- [ ] Public ALB → ECS `telemetry-api`.
  - Caption: **Schema validation, tenant validation, metric allowlist.**
- [ ] `telemetry-api` → ADOT/Prometheus Agent hoặc app remote_write.
  - Caption: **Convert validated telemetry to Prometheus samples.**
- [ ] remote_write component → AMP workspace.
  - Caption: **SigV4 Prometheus remote_write; bounded labels.**
- [ ] remote_write failure path → S3 `failure-buffer/`.
  - Caption: **Durable buffer for replay when AMP write fails.**

### Flow 2 - Prediction scheduling

- [ ] EventBridge Scheduler → SQS `prediction-jobs`.
  - Caption: **Every 5 minutes, enqueue tenant/service prediction job.**
- [ ] SQS `prediction-jobs` → ECS `prediction-worker`.
  - Caption: **Async worker decouples AI latency from ingest path.**
- [ ] SQS failed jobs → DLQ.
  - Caption: **Debug and replay failed prediction jobs.**

### Flow 3 - Worker builds AI signal window

- [ ] `prediction-worker` → AMP workspace.
  - Caption: **SigV4 PromQL query_range, 120-minute window, step=60s.**
- [ ] `prediction-worker` → DynamoDB service policy.
  - Caption: **Read enabled metrics, baseline version, fallback thresholds.**
- [ ] `prediction-worker` → S3 `baselines/` if needed.
  - Caption: **Read baseline JSON/evidence context.**

### Flow 4 - Private AI call via Service Connect

- [ ] `prediction-worker` → ECS Service Connect `ai-engine:8080`.
  - Caption: **Private service discovery/load balancing; no public internet/NAT.**
- [ ] ECS Service Connect → ECS `ai-engine` `/v1/predict`.
  - Caption: **POST /v1/predict; AI Engine verifies SigV4 in middleware/sidecar.**
- [ ] `ai-engine` → CloudWatch Logs.
  - Caption: **AI request/latency/error logs and metrics.**

### Flow 5 - Audit, alert, evidence

- [ ] `prediction-worker` → DynamoDB audit table.
  - Caption: **Append every prediction/fallback decision before deleting SQS message.**
- [ ] `prediction-worker` → S3 `evidence/`.
  - Caption: **Optional evidence snapshot for high-risk/debug.**
- [ ] `prediction-worker` → SNS.
  - Caption: **High-risk alert with evidence/audit reference.**
- [ ] SNS → SRE / Slack / email.
  - Caption: **Actionable warning and recommendation.**
- [ ] CloudWatch Dashboard/Alarms ← ECS/ALB/SQS/AMP/DynamoDB metrics.
  - Caption: **Operational evidence and failure detection.**

### Flow 6 - Fallback path

- [ ] AMP query fail / AI timeout / invalid AI schema → `prediction-worker` static threshold fallback.
  - Caption: **Fail-open monitoring: static threshold fallback, still audit.**
- [ ] Fallback decision → DynamoDB audit + SNS.
  - Caption: **No silent drop; SRE still receives evidence-backed alert.**

## 5. Security annotations cần đặt cạnh resource/flow

- [ ] Public ALB: **Only public entry point; HTTPS 443; demo CIDR/source allowlist if possible.**
- [ ] ECS services: **Private subnets, `assignPublicIp = DISABLED`.**
- [ ] AMP: **IAM/SigV4; PromQL scoped by tenant/service/metric/time.**
- [ ] Service Connect: **Private service discovery/load balancing only; does not verify SigV4.**
- [ ] AI Engine: **Middleware/sidecar verifies Worker SigV4 request in W12 final.**
- [ ] DynamoDB: **Audit is source of truth; encrypted; TTL 90 days.**
- [ ] S3: **Evidence/baseline/failure buffer; lifecycle policy; encrypted.**
- [ ] Secrets Manager/SSM: **No API key for Worker → AI; stores config/service name/webhooks/tokens only.**
- [ ] Labels: **Do not use `request_id`, `trace_id`, `prediction_id`, `user_id`, raw endpoint path as AMP labels.**
- [ ] Cost note: **Service Connect has no direct charge; watch proxy CPU/memory headroom.**

## 6. Diagram best-practice checklist

- [ ] Keep arrows left-to-right or top-to-bottom; avoid crossing arrows.
- [ ] Label every arrow with protocol/action, not just resource names.
- [ ] Separate data plane from control plane:
  - Data plane: ingest, remote_write, query_range, AI call, audit write.
  - Control plane: CI/CD, ECR image pull, Secrets/KMS, alarms.
- [ ] Use AWS managed-service icons outside the VPC boundary when they are regional managed services.
- [ ] Put ECS services inside private subnets, not directly beside external actors.
- [ ] Show only one public ALB for `/v1/ingest`.
- [ ] Show Worker → AI through ECS Service Connect inside private subnets.
- [ ] Show S3 and DynamoDB Gateway Endpoints connected to private route tables.
- [ ] Show NAT only for outbound AWS API calls not covered by Gateway Endpoints.
- [ ] Add small note: **AMP PrivateLink is hardening option, not MVP baseline.**
- [ ] Add small note: **Terraform implementation can follow this diagram; docs are current source of truth.**

## 7. Suggested caption for final diagram

> CDO-04 runs a cost-optimized SLO Early-Warning Control Plane in `us-east-1`. External demo services send telemetry through one public ALB to private ECS Fargate tasks. Telemetry is written to AMP via SigV4 remote_write. EventBridge and SQS trigger a Prediction Worker every 5 minutes; the Worker queries a 120-minute PromQL window from AMP, calls the private AI Engine through ECS Service Connect, writes every decision to DynamoDB audit, and sends high-risk alerts through SNS. If AMP or AI fails, the Worker uses static threshold fallback and still writes audit evidence.
