# Cost Analysis - Task Force 4 · CDO 04

<!-- Doc owner: Tạ Hoàng Huy (Huy) / CDO-04
     Status: Synced with AMP/us-east-1 accepted decision
     Region: us-east-1 (US East / N. Virginia)
     Date updated: 2026-06-26 -->

> **Scope note**: Platform không dùng LLM/Bedrock. AI Engine chạy statistical ML/FastAPI do CDO host trên ECS Fargate theo AI Deployment Contract. Cost "AI inference" trong tài liệu này là ECS Fargate runtime + private Service Connect service traffic, không phải token cost.

---

## 1. Final cost

### 1.1 Official region and compute decision

| Item | Final decision |
|---|---|
| Region chính thức | `us-east-1` (US East / N. Virginia), aligned với default `AWS_REGION` của AI Deployment Contract |
| Compute model | All core runtime on ECS Fargate Linux/x86 |
| ECS services | Telemetry API, Prediction Worker, AI Engine Service |
| Metric backend | Amazon Managed Service for Prometheus (AMP) |
| AI serving | ECS Fargate service, private subnet, API Gateway HTTP API `AWS_IAM` → VPC Link → same ALB restricted listener `:8443` → AI target group; ECS Service Connect kept as rollback/fallback |
| Prediction cadence | Every 5 minutes |
| Telemetry frequency | Every 1 minute |
| AI lookback window | Đúng/đủ 120 phút gần nhất |
| Budget target | ≤ $200/month |

All-ECS được chọn vì CDO phải host AI Engine như ECS Fargate service trong private subnet, có health check, scaling, ECS rolling deployment circuit breaker rollback và IAM task role rõ ràng. Path A thêm API Gateway HTTP API làm SigV4 enforcement point cho Worker → AI, rồi dùng VPC Link tới same existing ALB restricted listener `:8443`. Service Connect giữ làm rollback/fallback trong migration. Lambda AI được giữ như future cost optimization only, không phải final decision.

### 1.2 us-east-1 + AMP aligned with `02_infra_design.md`

| Component | AWS Service | Config | Estimate/month |
|---|---|---|---:|
| Core compute | ECS Fargate x86 | 5 tasks total: Telemetry API 2 + Prediction Worker 1 + AI Engine 2, each 0.5 vCPU / 1GB | **$90.10** |
| Application Load Balancer | 1 ALB + 1 LCU | Public ingest ALB `/v1/ingest` plus restricted `:8443` AI listener on same ALB; no second ALB | **$22.27** |
| API Gateway HTTP API | HTTP API + VPC Link | `AWS_IAM`/SigV4 enforcement for Worker → AI; ~25,920 AI POST calls/month × (`$1/M` HTTP API requests + ~0.00012GB/request NAT data for full 120m payload) | **$0.17** |
| NAT Gateway | VPC | 1 NAT Gateway theo một AZ + ~12GB base AWS API data processing; Worker private subnet uses NAT for outbound to public execute-api endpoint, with Path A request payload cost counted in API Gateway row | **$33.39** |
| Amazon Managed Service for Prometheus | AMP workspace | Prometheus remote_write/query_range, 120-minute PromQL filtered window, 150-day default retention | **~$0.00** |
| DynamoDB audit/policy | DynamoDB on-demand | ~26k prediction audit writes/month + service policy reads | **$0.10** |
| EventBridge + SQS/DLQ | Managed orchestration | ~26k prediction jobs/month, ~3 SQS requests/job | **$0.05** |
| S3 baseline/evidence/failure buffer | S3 + KMS lifecycle | Baseline JSON prefix `baselines/`, evidence export, 7-day raw failure buffer | **$0.35** |
| CloudWatch + SNS | Logs, metrics, dashboard, alarms, notifications | 14-day app logs; AI internal audit logs are KMS encrypted with 365-day retention | **$8.00** |
| Secrets Manager + KMS | Config/encryption | Endpoint config, webhook/tenant secret, KMS keys | **$3.40** |
| ECR | Private registry | Small images + lifecycle policy | **$0.50** |
| **Full always-on total** |  | Network path uses 1 zonal NAT + S3/DynamoDB Gateway Endpoints; TSDB uses AMP; Worker → AI uses API Gateway HTTP API + VPC Link + same ALB restricted listener | **~$158.33** |
| **+20% ops buffer** |  | Buffer for operational variance, logs, small request deltas and API Gateway request growth | **~$190.00** |

> Pricing note: AWS Pricing MCP facts used here for `us-east-1`: Fargate x86 $0.04048/vCPU-hour + $0.004445/GB-hour; ALB $0.0225/hour + $0.008/LCU-hour; NAT $0.045/hour + $0.045/GB. AMP pricing is usage-based: first 40M ingested samples/month and first 10GB storage are effectively enough for demo volume; query samples are billed from usage but ~21.8M/month is about $0.0022 and rounds to $0.00. These are capstone estimates to defend budget, not a replacement for AWS Cost Explorer.

### 1.3 Budget fit

| Scope | Estimate/month | Budget fit |
|---|---:|---|
| 3 demo services full always-on x86 design with AMP and API Gateway Path A | **~$158.33** | Under hard $200 budget by about **$41.67** |
| Same estimate + 20% ops buffer | **~$190.00** | Still under hard $200 budget by about **$10.00** |
| Service Connect proxy upsize sensitivity | Variable | If proxy sidecar forces task-size increases, re-estimate Fargate compute before claiming the buffered budget |

Final strategy: keep ECS Fargate x86 as accepted decision, keep prediction cadence at 5 minutes, enforce PromQL query scoping, control metric cardinality, keep logs retention fixed and keep audit/fallback active. ARM64/Graviton remains a future optimization, not the accepted decision; the full x86 design fits the hard $200 target before and after the 20% buffer if no Service Connect proxy upsize is required.

---

## 2. Telemetry and prediction volume model

### 2.1 Required AI signals

Final AI telemetry contract is **1 sample/minute** with 7 required signals/service:

```text
cpu_usage_percent
memory_usage_percent
active_connections
db_connection_pool_pct
queue_depth
cache_hit_rate_pct
api_latency_ms
```

```text
7 metrics × 60 minutes × 24 hours × 30 days = 302,400 metric points/service/month
3 services = 907,200 metric points/month
```

`error_rate` và `oldest_message_age_seconds` có thể được giữ cho dashboard/fallback nội bộ, nhưng không tính là required AI signals nếu chưa nằm trong AI Telemetry Contract.

### 2.2 Prediction cycles and AMP query samples

```text
3 services × 12 cycles/hour × 24 hours × 30 days = 25,920 prediction cycles/month
Each prediction query ~= 7 metrics × 120 one-minute samples = 840 query samples
25,920 cycles × 840 = 21,772,800 query samples/month
```

| Metric | Value |
|---|---:|
| Prediction cadence | 5 minutes |
| Lookback window per AI call | 120 minutes |
| Monthly prediction cycles | ~25,920 |
| AMP ingested samples/month | ~907,200 |
| AMP worker query samples/month | ~21.8M |
| Cost per prediction cycle | ~$158.33 / 25,920 = **~$0.0061/cycle** |
| Cost per demo service | ~$158.33 / 3 = **~$52.78/service/month** |

Runtime AMP PromQL queries must always filter by `tenant_id`, `service_id`, metric name and exact time window to avoid query latency and cost spikes. During testing, use query stats/metadata where possible to watch query samples processed.

### 2.3 50k events/sec caveat

The AI Telemetry Contract mentions a **50,000 events/sec peak** design ceiling. For AMP, this must be translated into Prometheus samples/sec:

```text
samples/sec = events/sec × số sample phát sinh trên mỗi event
```

Therefore the ceiling is viable only if:

- samples/event is bounded;
- labels are bounded and low-cardinality;
- labels do not include `request_id`, `trace_id`, `prediction_id`, `user_id`, raw endpoint path or other unbounded values;
- remote_write batching stays within request-size limits;
- load tests ramp gradually instead of suddenly doubling active series.

Phạm vi demo nhỏ hơn nhiều so với ceiling này và vẫn fit ngân sách. Nếu load test nhắm tới 50k events/sec, docs/tests phải tính samples/sec trước. Ví dụ: 50k events/sec × 7 samples/event = 350k samples/sec, cao hơn mặc định AMP 70k samples/sec, nên cần tăng quota hoặc giảm mục tiêu load.

---

## 3. Guardrail chi phí

### 3.1 Guardrail chi phí cho Terraform v1

Các giá trị mặc định của Terraform phải giữ mức cap $200/month thực tế:

- chỉ dùng một NAT Gateway theo một AZ;
- bật S3/DynamoDB Gateway Endpoints;
- interface endpoints mặc định tắt;
- Service Connect TLS / AWS Private CA tắt;
- AWS WAF tắt;
- AMP managed collector tắt; dùng ADOT ECS collector tự quản lý;
- ECS Container Insights mặc định tắt;
- AI desired count 2, max 4 chỉ qua autoscaling;
- thời gian giữ application log 14 ngày cho non-prod và 30 ngày cho prod/demo;
- đích nhận alert là SNS email; xác nhận subscription làm thủ công.

Các yếu tố phá ngân sách cần tránh nếu chưa được phê duyệt rõ:

| Thay đổi | Tác động chi phí/tháng ước tính |
|---|---:|
| AI chạy 4 tasks toàn thời gian thay vì 2 | +~$36/tháng |
| 5 interface endpoints trên 2 AZ | +~$73/tháng |
| 8 interface endpoints trên 2 AZ | +~$116.80/tháng |
| AMP managed collector | +$29.20/tháng cho mỗi collector |
| Service Connect TLS / AWS Private CA | Thêm chi phí/độ phức tạp cho Private CA, cert, Secrets Manager và KMS |

### 3.2 50/80/100 policy

Quy tắc lõi: **Không bao giờ tắt DynamoDB audit logging hoặc static threshold fallback.**

| Threshold | Budget level | Action |
|---|---:|---|
| 50% | $100/month | Alert only. SRE kiểm tra synthetic load schedule, CloudWatch log volume và AMP active series. Không scale service tự động. |
| 80% | $160/month | Alert + manual review/runbook. Giữ prediction cadence ở 5 phút, review PromQL scoping, high-cardinality labels và DEBUG logs. Không scale service tự động. |
| 100% | $200/month | Emergency breaker scale down chỉ `prediction-worker` và `ai-engine` về 0 desired tasks. Giữ `telemetry-api` chạy để ingest/health không mất. Rollback runbook khôi phục desired count sau khi được duyệt. |

### 3.3 Budget Terraform sketch

```hcl
resource "aws_budgets_budget" "platform_budget" {
  name         = "tf4-cdo04-platform-budget"
  budget_type  = "COST"
  limit_amount = "200"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 50
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 80
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 100
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }
}
```

---

## 4. NAT Gateway vs VPC Endpoint decision

### 4.1 Scope

This section follows `02_infra_design.md`: AI Engine is internal in the same VPC/ECS platform, but Path A puts API Gateway in front to enforce SigV4.

```text
Region: us-east-1
Topology: 2 AZ, private ECS tasks, public ALB for ingest
Runtime: Telemetry API + Prediction Worker + AI Engine
Luồng AI: Worker private subnet -> NAT -> API Gateway execute-api -> VPC Link -> same ALB :8443 -> AI Engine
AWS API traffic model: ~12GB/month
```

### 4.2 Final network cost model

| Model | Monthly cost at ~12GB/month | Decision |
|---|---:|---|
| 1 zonal NAT + S3/DynamoDB Gateway Endpoints | **~$33.39** | ✅ Final decision |
| 2 NAT Gateways + S3/DynamoDB Gateway Endpoints | Higher fixed cost | Production HA hardening option |
| Full Interface VPCE no-NAT | Higher fixed endpoint cost at demo traffic | Security-first hardening option, not MVP |

Final decision: **1 NAT Gateway theo một AZ + S3/DynamoDB Gateway Endpoints**. This is not the strongest private-only posture, but it is the best cost-security fit for capstone traffic. S3 and DynamoDB paths stay on Gateway Endpoints; remaining AWS API traffic, including AMP MVP access, can go through NAT with IAM least privilege and HTTPS-only egress where possible.

### 4.3 PrivateLink hardening path

Production hardening path:

1. Keep S3 + DynamoDB Gateway Endpoints.
2. Add `aps-workspaces` interface endpoint for AMP remote_write/query if private-only AMP data-plane access is required.
3. If removing NAT, add STS regional endpoint plus ECR API/Docker, CloudWatch Logs, Secrets Manager, KMS, SQS, SNS and other runtime endpoints by priority.
4. Remove NAT only after every runtime AWS API path has an endpoint.

---

## 5. Cost optimization applied

- [x] **All-ECS but right-sized**: 0.5 vCPU / 1GB per task for Telemetry API, Worker and AI Engine; AI min 2, max 4 theo AI Deployment Contract.
- [x] **x86 Fargate**: explicitly selected for compatibility and contract stability; ARM64 remains future optimization.
- [x] **1 NAT Gateway theo một AZ**: cheaper than NAT per AZ for capstone. Accepted trade-off: NAT egress is not fully HA, but Worker → AI does not depend on NAT.
- [x] **S3/DynamoDB Gateway Endpoints**: no hourly endpoint charge; reduces NAT data processing for S3/DynamoDB paths.
- [x] **AMP usage-based metrics backend**: removes fixed managed InfluxDB instance-hour cost.
- [x] **PromQL query discipline**: every runtime query must filter by tenant, service, metric name and 120-minute window.
- [x] **Label cardinality guardrail**: no high-cardinality labels; bounded samples/event.
- [x] **CloudWatch retention**: application logs 14 days; AI internal audit logs 365 days, KMS encrypted.
- [x] **S3 lifecycle policy**: raw failure buffer 7 days; baseline/evidence/telemetry archive minimum 90 days.
- [x] **ECR lifecycle policy**: keep recent images, preserve final release tags.

Not applied:

- [ ] **Fargate Spot for core services**: not chosen for Telemetry API or AI Engine because availability and predictable demo behavior matter more.
- [ ] **Savings Plans**: not useful for short capstone usage, but valid production optimization.
- [ ] **Bedrock prompt caching**: not applicable; no Bedrock/LLM/token cost.

---

## 6. Cost vs alternatives

| Option | Cost impact | Why not final |
|---|---:|---|
| Previous Singapore + Timestream for InfluxDB | About $296.04/month full-month always-on | Superseded by ADR-011 because fixed `db.influx.medium` cost breaks full-month $200 budget target. |
| AMP + us-east-1 + x86 Fargate with public ALB + API Gateway Path A | About $158.33/month; $190.00 with 20% buffer | ✅ Accepted physical design; fits hard $200 before and after buffer while enforcing Worker → AI SigV4 at API Gateway. |
| AMP + us-east-1 + ARM64 Fargate | Lower compute cost | Future optimization only; x86 is accepted decision for compatibility. |
| Hybrid ECS + Lambda AI | Lower AI idle cost | Rejected for final because AI Deployment Contract says CDO hosts AI Engine as ECS Fargate service with task definition rollback. |
| Serverless-all-in | Lowest cost | Weakens CDO control-plane story, internal service routing, ECS deployment evidence and alignment with client ECS context. |
| Full Interface VPCE no-NAT | Stronger private-only posture | Too much fixed endpoint cost for capstone traffic. |
| 2 NAT Gateways | Better AZ-level egress HA | Higher cost; not required for MVP. Production hardening option. |
| EKS | Platform-flexible | Overkill and adds control-plane cost/ops complexity. |

---

## 7. Production recommendations

- **Keep AMP label discipline strict**: tenant/service/env/region labels are fine; request/user/trace/prediction IDs are not labels.
- **Use collector-managed remote_write** where possible. Direct app remote_write must implement protobuf, Snappy, SigV4, batching, retry/backoff and request-size control.
- **Add AMP PrivateLink later** only if security/compliance requires private-only data-plane access.
- **Move to ARM64/Graviton** only after all images and dependencies support it; not the accepted decision today.
- **Tune CloudWatch logs/custom metrics** aggressively; logs and custom metrics are easy to overproduce during load testing.

---

## 8. Final cost evidence gate

Runtime cost evidence is generated during final acceptance:

- `evidence/logs/cost-explorer-final.json`
- `evidence/logs/budget-final.json`

Current final test evidence focuses on live ingest/AI path. Cost Explorer same-day actuals remain delayed supporting evidence only; budget/circuit-breaker configuration plus the sizing model above remain the cost proof.

Pass rule:

| Item | Requirement |
|---|---|
| Budget exists | `tf4-cdo04-platform-budget-sandbox` or configured `BUDGET_NAME` exists |
| Budget cap | <= `$200.00` |
| Forecast | < `$200.00` |
| Actual snapshot | no unexpected sandbox spike during test window |
| Circuit breaker | budget policy and scale-down runbook documented |

Cost Explorer same-day or 7-day sandbox actuals are supporting evidence only. They do **not** prove full-month operating cost. Final defense uses the design estimate in this document plus Budget API/circuit-breaker evidence from the current acceptance run.

## 9. Final defense statement

All-ECS Fargate is not the cheapest possible option, but it is the most consistent option for this CDO platform. The platform must run Telemetry API, Prediction Worker and AI Engine Service as deployable workloads with health checks, CloudWatch logs, task roles, autoscaling and rollback. AI serving stays private behind API Gateway HTTP API `AWS_IAM`, VPC Link, and the same ALB restricted listener `:8443`; ECS Service Connect remains migration fallback. The final TSDB choice is **Amazon Managed Service for Prometheus (AMP) in `us-east-1`**, replacing fixed-cost Timestream for InfluxDB. The accepted full-month x86 design with public ingest ALB plus API Gateway Path A is **~$158.33/month**; with 20% buffer it is **~$190.00/month**, still under the $200/month target. The key operating guardrails are PromQL scoping, bounded label cardinality, bounded samples/event, fixed log retention, API Gateway auth probes and keeping audit/fallback active even when reducing non-critical load.

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md) — region, cadence, lookback and contract requirements.
- [`02_infra_design.md`](02_infra_design.md) — all-ECS Fargate architecture and network path.
- [`04_deployment_design.md`](04_deployment_design.md) — CI/CD, rollout and rollback.
- [`07_test_eval_report.md`](07_test_eval_report.md) — validation scenarios and cost-related tests.
- [`08_adrs.md`](08_adrs.md) — ADR-011 final AMP/us-east-1 decision.
