# Cost Analysis - Task Force 4 · CDO 04

<!-- Doc owner: Tạ Hoàng Huy (Huy) / CDO-04
     Status: Synced with 02_infra_design.md final baseline
     Region: ap-southeast-1 (Singapore)
     Date updated: 2026-06-26 -->

> **Scope note**: Platform không dùng LLM/Bedrock. AI Engine chạy statistical ML/FastAPI do CDO host trên ECS Fargate theo AI Deployment Contract. Cost "AI inference" trong tài liệu này là ECS Fargate runtime + internal ALB/service traffic, không phải token cost.

---

## 1. Final cost baseline

### 1.1 Official region and compute decision

| Item | Final decision |
|---|---|
| Region chính thức | `ap-southeast-1` (Singapore) theo AI Deployment Contract |
| Compute model | All core runtime on ECS Fargate |
| ECS services | Telemetry API, Prediction Worker, AI Engine Service |
| AI serving | ECS Fargate service, private subnet, internal ALB route `POST /v1/predict` |
| Prediction cadence | Every 5 minutes |
| Telemetry frequency | Every 1 minute |
| AI lookback window | Đúng/đủ 120 phút gần nhất |
| Budget target | ≤ $200/month |

All-ECS được chọn vì CDO phải host AI Engine như ECS Fargate service trong private subnet, expose qua internal ALB DNS, có health check, scaling, canary rollback và IAM task role rõ ràng. Route 53/private DNS không nằm trong baseline MVP; nếu cần hostname ổn định thì đó là production hardening. Lambda AI được giữ như future cost optimization only, không phải final baseline.

### 1.2 Singapore baseline aligned with `02_infra_design.md`

| Component | AWS Service | Config | Estimate/month |
|---|---|---|---:|
| Core compute | ECS Fargate | 5 tasks total: Telemetry API 2 + Prediction Worker 1 + AI Engine 2, each 0.5 vCPU / 1GB | **$112.46** |
| Application Load Balancer | ALB + 1 LCU | Public ingest route `/v1/ingest` + internal/private predict route `/v1/predict` | **$24.24** |
| NAT Gateway | VPC | 1 zonal NAT Gateway + ~12GB data processing | **$43.78** |
| Amazon Timestream for InfluxDB | TSDB metrics | db.influx.medium Single-AZ, 120-minute Flux filtered window, 90-day bucket retention target | **$103.66** |
| DynamoDB audit/policy | DynamoDB on-demand | ~26k prediction audit writes/month + service policy reads | **$0.10** |
| EventBridge + SQS/DLQ | Managed orchestration | ~26k prediction jobs/month, ~3 SQS requests/job | **$0.05** |
| S3 baseline/evidence/failure buffer | S3 + KMS lifecycle | Baseline JSON prefix `baselines/`, evidence export, 7-day raw failure buffer | **$0.35** |
| CloudWatch + SNS | Logs, metrics, dashboard, alarms, notifications | 14-day app logs; AI internal audit logs are KMS encrypted with 365-day retention | **$8.00** |
| Secrets Manager + KMS | Config/encryption | Endpoint config, webhook/tenant secret, KMS keys | **$3.40** |
| ECR | Private registry | Small images + lifecycle policy | **~$0.10-$1.00** |
| **Full always-on baseline total** |  | Network path uses 1 zonal NAT + S3/DynamoDB Gateway Endpoints; TSDB uses db.influx.medium Single-AZ | **~$296.04** |

> Pricing note: tài liệu này chỉ giữ số liệu final tại `ap-southeast-1`; không dùng lại bảng so sánh region cũ. AWS Pricing MCP facts used here: Fargate x86 $0.05056/vCPU-hour + $0.00553/GB-hour; Fargate ARM $0.04045/vCPU-hour + $0.00442/GB-hour; ALB $0.0252/hour + $0.008/LCU-hour; NAT $0.059/hour + $0.059/GB; Timestream for InfluxDB **db.influx.medium Single-AZ** $0.142/hour (~$103.66/month at 730h). Đây là minimum viable InfluxDB option cho baseline; docs chính không track larger instance options để tránh nhiễu quyết định. Các con số là capstone estimate để defend budget, không thay thế AWS bill thực tế.

### 1.3 Why full always-on no longer fits the budget

| Cost item | Why it matters |
|---|---|
| ECS Fargate 5 tasks | Chi phí lớn nhất vì Telemetry API, Worker và AI Engine đều chạy container/private subnet. AI Engine phải giữ min 2 tasks theo AI contract. |
| ALB | Cần cho public ingest HTTPS và internal/private predict route. ACM không tính phí, nhưng ALB/LCU có fixed runtime cost. |
| NAT Gateway | 1 zonal NAT giữ cost thấp hơn 2 NAT hoặc full Interface VPCE; S3/DynamoDB Gateway Endpoints giảm data processing cho evidence/audit path. |
| CloudWatch/SNS | Cần logs, alarms, dashboard, AI p99/fallback/audit alarms; AI internal audit retention 365 ngày được tách khỏi app log 14 ngày. |

Với Timestream for InfluxDB, full always-on baseline **~$296.04/month** không còn fit budget $200. Phần thay đổi chính là TSDB: estimate generic $5/month cũ bị thay bằng minimum viable `db.influx.medium` **$103.66/month**. Vì vậy budget defense phải nói rõ mitigation: chạy đúng 2-week capstone window, teardown hoặc stop non-demo stacks ngoài giờ test/demo, dùng ARM64/Graviton cho ECS khi image hỗ trợ, giữ synthetic load ngắn và xin budget exception nếu bắt buộc chạy always-on cả tháng.

### 1.4 Monthly total and budget fit

| Scope | Baseline/month | Budget fit |
|---|---:|---|
| 3 demo services full always-on baseline with db.influx.medium | **~$296.04** | Vượt $200 khoảng **$96.04**; dùng khoảng **148.0%** budget |
| Same baseline + 20% ops buffer | **~$355.25** | Vượt $200 rõ rệt; buffer là risk buffer, không phải provisioned capacity cố định |
| ARM64 ECS mitigation + db.influx.medium | **~$273.53** | Giảm compute khoảng $22.51/month nhưng vẫn vượt $200; cần thêm schedule/teardown hoặc budget exception |

Final strategy: keep synthetic load short-lived, log retention fixed, no prediction cadence below 5 minutes, prefer ARM64/Graviton when image support is confirmed, and teardown non-demo resources outside test/demo windows. **Core audit/fallback must stay active.**

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

### 2.2 Prediction cycles

```text
3 services × 12 cycles/hour × 24 hours × 30 days = 25,920 prediction cycles/month
```

| Metric | Value |
|---|---:|
| Prediction cadence | 5 minutes |
| Lookback window per AI call | 120 minutes |
| Monthly prediction cycles | ~25,920 |
| Baseline cost per prediction cycle | ~$296.04 / 25,920 = **~$0.0114/cycle** |
| Baseline cost per demo service | ~$296.04 / 3 = **~$98.68/service/month** |

Runtime Timestream for InfluxDB Flux queries must always filter by `tenant_id`, `service_id`, `metric_type`, and exact time window to avoid cost spikes.

---

## 3. Cost guardrails

### 3.1 50/80/100 policy

Core rule: **Never disable DynamoDB audit logging or static threshold fallback.**

| Threshold | Budget level | Action |
|---|---:|---|
| 50% | $100/month | SNS/email warning; confirm synthetic load schedule and CloudWatch log volume. |
| 80% | $160/month | Freeze prediction cadence at 5 minutes; review Timestream for InfluxDB Flux queries; reduce DEBUG logs. |
| 100% | $200/month | Pause non-critical synthetic load and non-critical prediction experiments. Keep critical prediction/fallback/audit path active. If AI Engine must be emergency scaled down, Worker must automatically use static threshold fallback and still write audit. |

### 3.2 Budget Terraform sketch

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

This section follows `02_infra_design.md`: AI Engine is internal in the same VPC/ECS platform, so Worker → AI does **not** use NAT or public internet.

```text
Region: ap-southeast-1
Topology: 2 AZ, private ECS tasks, public ALB for ingest
Runtime: Telemetry API + Prediction Worker + AI Engine
AI path: Worker -> internal ALB DNS -> AI Engine
AWS API traffic model: ~12GB/month
```

### 4.2 Final network cost model

| Model | Monthly cost at ~12GB/month | Decision |
|---|---:|---|
| 1 zonal NAT + S3/DynamoDB Gateway Endpoints | **~$43.78** | ✅ Final baseline |
| 2 NAT Gateways + S3/DynamoDB Gateway Endpoints | Higher fixed cost | Production HA hardening option |
| Full Interface VPCE no-NAT | Much higher fixed endpoint cost at demo traffic | Security-first hardening option, not baseline |

Final decision: **1 zonal NAT Gateway + S3/DynamoDB Gateway Endpoints**. This is not the strongest private-only posture, but it is the best cost-security fit for capstone traffic. S3 and DynamoDB paths stay on free Gateway Endpoints; remaining AWS API traffic goes through NAT with IAM least privilege and HTTPS-only egress where possible.

### 4.3 Why not full Interface VPCE baseline

Full no-NAT would need private paths/endpoints for runtime services such as ECR API/Docker, CloudWatch Logs/Metrics, Secrets Manager, KMS, SQS, SNS, and Timestream for InfluxDB endpoint access. With 2 AZ, fixed endpoint hourly cost is materially higher than one NAT Gateway for ~12GB/month demo traffic.

Production hardening path:

1. Keep S3 + DynamoDB Gateway Endpoints.
2. Add `logs`/`monitoring` endpoint if CloudWatch private path becomes required.
3. Keep Timestream for InfluxDB endpoint private with SG controls; add/adjust private connectivity if TSDB hot path must be private-only.
4. Add SQS/SNS/Secrets/KMS/ECR endpoints by priority.
5. Remove NAT only after every runtime AWS API path has an endpoint.

---

## 5. Cost optimization applied

- [x] **All-ECS but right-sized**: 0.5 vCPU / 1GB per task for Telemetry API, Worker and AI Engine; AI min 2, max 4 theo AI Deployment Contract.
- [x] **1 zonal NAT Gateway**: cheaper than NAT per AZ for capstone. Accepted trade-off: NAT egress is not fully HA, but Worker → AI does not depend on NAT.
- [x] **S3/DynamoDB Gateway Endpoints**: no hourly endpoint charge; reduces NAT data processing for S3/DynamoDB paths.
- [x] **No full Interface VPCE baseline**: too much fixed cost for demo traffic; reserved for production hardening.
- [x] **Timestream for InfluxDB Flux query discipline**: every runtime query must filter by tenant, service, metric type, and 120-minute window.
- [x] **CloudWatch retention**: application logs 14 days; AI internal audit logs 365 days, KMS encrypted.
- [x] **S3 lifecycle policy**: raw failure buffer 7 days; baseline/evidence/telemetry archive minimum 90 days.
- [x] **ECR lifecycle policy**: keep recent images, preserve final release tags.
- [x] **Synthetic load window control**: load tests are scheduled and time-boxed; not part of always-on baseline.

Not applied:

- [ ] **Fargate Spot for core services**: not chosen for Telemetry API or AI Engine because availability and predictable demo behavior matter more.
- [ ] **Savings Plans**: not useful for 2-week capstone, but valid production optimization.
- [ ] **Bedrock prompt caching**: not applicable; no Bedrock/LLM/token cost.

---

## 6. 2-week capstone budget estimate

| Service | Forecast 2 weeks | Notes |
|---|---:|---|
| ECS Fargate 5 tasks | ~$56.23 | Half-month of $112.46 baseline |
| ALB + LCU | ~$12.12 | Half-month of $24.24 baseline |
| NAT Gateway + data | ~$21.89 | Half-month of $43.78 baseline |
| Timestream for InfluxDB | ~$51.83 | Half-month of db.influx.medium Single-AZ ($103.66/month) |
| DynamoDB/SQS/S3 | ~$0.25 | Audit, queue, evidence/failure buffer |
| CloudWatch/SNS | ~$4.00 | Logs/dashboard/alarms |
| Secrets/KMS/ECR | ~$2.20 | Secrets, encryption, image storage |
| **Total forecast 2 weeks** | **~$148.02** | Below $200 for a 2-week capstone window, but not safe as a full-month always-on baseline |

### 6.1 Measured actual (Pack #2 — fill in W12)

| Service | Forecast | Actual | Delta |
|---|---:|---:|---:|
| ECS Fargate | $56.23 | - | - |
| ALB + LCU | $12.12 | - | - |
| NAT Gateway + data | $21.89 | - | - |
| Timestream for InfluxDB | $51.83 | - | - |
| DynamoDB/SQS/S3 | $0.25 | - | - |
| CloudWatch/SNS | $4.00 | - | - |
| Secrets/KMS/ECR | $2.20 | - | - |
| **Total** | **$148.02** | **-** | **-** |

### 6.2 Cost-per-correct-decision forecast

```text
25,920 prediction cycles/month / 2 = ~12,960 cycles for 2 weeks
Expected correct decisions if catch rate >=80% = ~10,368
```

| Metric | Forecast | Actual |
|---|---:|---:|
| Total prediction cycles in 2-week capstone | ~12,960 | - |
| Correct decisions at 80% catch rate | ~10,368 | - |
| Total platform cost | ~$148.02 | - |
| **Cost per correct decision** | **~$0.0143** | - |

---

## 7. Cost vs alternatives

| Option | Cost impact | Why not final |
|---|---:|---|
| Hybrid ECS + Lambda AI | Lower AI idle cost | Rejected for final because AI Deployment Contract says CDO hosts AI Engine as ECS Fargate service with internal ALB and task definition/CodeDeploy rollback. Kept as future optimization only. |
| Serverless-all-in | Lowest cost | Weakens CDO control-plane story, internal service routing, ECS deployment evidence and alignment with client ECS context. |
| Full Interface VPCE no-NAT | Stronger private-only posture | Too much fixed endpoint cost for capstone traffic. |
| 2 NAT Gateways | Better AZ-level egress HA | Higher cost; not required for MVP. Production hardening option. |
| EKS | Platform-flexible | Overkill and adds control-plane cost/ops complexity. |

---

## 8. Production recommendations

- **Move to ARM64/Graviton** if all images and dependencies support it; this is the safest cost optimization because it does not change the architecture.
- **Keep AI Engine ECS for final MVP**, but revisit Lambda container only after W12 if cost becomes more important than p99 predictability and CodeDeploy canary alignment.
- **Add Interface Endpoints incrementally** only where security/compliance requires it or traffic grows enough to justify fixed endpoint cost.
- **Use Compute Savings Plans** only for long-running production usage, not for the short capstone window.
- **Tune CloudWatch logs/custom metrics** aggressively; logs and custom metrics are easy to overproduce during load testing.

---

## 9. Final defense statement

All-ECS Fargate is not the cheapest option, but it is the most consistent option for this CDO platform. The platform must run Telemetry API, Prediction Worker and AI Engine Service as deployable workloads with health checks, CloudWatch logs, task roles, autoscaling and rollback. AI Deployment Contract also states that CDO hosts AI Engine as ECS Fargate service in private subnet behind internal ALB. The final TSDB choice is Amazon Timestream for InfluxDB in Singapore, and its db.influx.medium fixed instance cost changes the budget story: **full always-on baseline is ~$296.04/month**, so it does **not** fit a $200/month cap without mitigation. The defensible capstone plan is to run the platform in the 2-week window (~$148.02 forecast), use ARM64/Graviton where possible, teardown outside demo/test windows, and keep audit/fallback active even when reducing non-critical load.

## Related documents

- [`01_requirements_analysis.md`](01_requirements_analysis.md) — region, cadence, lookback and contract requirements.
- [`02_infra_design.md`](02_infra_design.md) — all-ECS Fargate architecture and network path.
- [`04_deployment_design.md`](04_deployment_design.md) — CI/CD, rollout and rollback.
- [`07_test_eval_report.md`](07_test_eval_report.md) — validation scenarios and cost-related tests.
- [`08_adrs.md`](08_adrs.md) — ADR-005, ADR-008 and ADR-009.
