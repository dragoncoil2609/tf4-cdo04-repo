# Cost Analysis - Task Force 4 · CDO 04

<!-- Doc owner: Tạ Hoàng Huy (Huy)
     Status: Refined (W11 T6 Pack #1) - v1.2
     Word target: 1000-1500 từ -->

> **Scope note**: Platform của nhóm không dùng LLM/Bedrock. AI Engine (Nhóm AI) chạy statistical ML.
> Cost "AI inference" trong doc này = data transfer CDO→AI endpoint + Fargate compute của Prediction Worker,
> không phải per-token LLM cost. Điều này là điểm khác biệt cốt lõi so với template mặc định.

---

## 1. Cost model per tenant (forecast)

> **Định nghĩa "tenant" trong TF4**: một service được monitor (ví dụ `payment-gateway`) với per-service
> baseline riêng biệt. Capstone demo với 3 tenant/service. Production scale = số service tier-1 được onboard.

### 1.1 Shared fixed cost (platform-level, amortized)

Chi phí này tồn tại độc lập với số lượng tenant và được chia đều cho toàn bộ hệ thống:

| Component | AWS Service | Config | $/month (fixed) |
|---|---|---|---|
| Telemetry API | ECS Fargate | 0.25 vCPU · 0.5GB RAM · always-on | ~$9.01 |
| Prediction Worker | ECS Fargate | 0.25 vCPU · 0.5GB RAM · event-driven | ~$5.00 |
| NAT Gateway | VPC | 1 NAT · ap-southeast-1 (Singapore) | ~$43.07 |
| CloudWatch Dashboard | CloudWatch | 1 dashboard dùng chung | ~$3.00 |
| EventBridge Scheduler | Scheduler | ~8,640 invocations/tháng/3 service | ~$0.01 |
| **Total fixed** | | | **~$60.09/month** |

> **Lưu ý NAT Gateway**: $43.07/tháng (tính theo đơn giá $0.059/giờ tại Singapore) là chi phí cố định lớn nhất, chiếm hơn 70% tổng chi phí cố định. Chúng ta bypass bằng VPC Endpoints (xem §3) để tối ưu hóa tối đa.

### 1.2 Variable cost per tenant (per service monitored)

| Component | AWS Service | Unit cost | Tenant avg usage/month | $/tenant/month |
|---|---|---|---|---|
| Metric ingest | Amazon Timestream (write) | $0.62/million writes | ~259,200 writes (1 write/phút × 6 metric × 30 ngày) | ~$0.16 |
| Metric storage | Amazon Timestream (magnetic) | $0.0036/GB-month | ~0.5 GB | ~$0.002 |
| Prediction query | Amazon Timestream (query) | $0.01/GB scanned | ~8 GB scanned (8,640 queries × ~1MB/query) | ~$0.08 |
| Audit log write | DynamoDB (on-demand) | $1.25/million WCU | ~8,640 writes | ~$0.01 |
| Audit log storage | DynamoDB | $0.25/GB-month | ~0.3 GB | ~$0.08 |
| CloudWatch logs | CloudWatch | $0.50/GB ingested | ~0.5 GB app log/service | ~$0.25 |
| CloudWatch metrics | CloudWatch | $0.30/metric/month | ~6 custom metric/service (giới hạn tối ưu) | ~$1.80 |
| SNS alert | SNS | Mức cơ bản | <1,000 notifications | ~$0.00 |
| SQS (prediction queue) | SQS | $0.40/million requests | ~17,280 messages | ~$0.01 |
| AI endpoint call | Data transfer internal | ~$0 (VPC-internal) | 8,640 calls | ~$0.00 |
| **Total variable / tenant / month** | | | | **~$2.39** |

### 1.3 Total per-tenant cost (platform amortized)

| Tenant count | Fixed cost/month | Variable/month | **Total/month** | **Per-tenant** |
|---|---|---|---|---|
| 3 (capstone demo) | $60.09 | $7.17 | **$67.26** | **$22.42** |
| 10 | $60.09 | $23.90 | **$83.99** | **$8.40** |
| 50 | $60.09 | $119.50 | **$179.59** | **$3.59** |

---

## 2. Cost at scale

| Tenant count | Monthly total | Avg per-tenant | Ghi chú |
|---|---|---|---|
| 3 | ~$67 | ~$22.42 | Môi trường Capstone Demo — fixed cost chưa được phân bổ tối ưu |
| 10 | ~$84 | ~$8.40 | Quy mô sản xuất nhỏ (Small Production) |
| 50 | ~$180 | ~$3.59 | Quy mô mục tiêu (Production Target) — vẫn nằm dưới budget $200 |
| 100 | ~$299 | ~$2.99 | Vượt budget $200 — cần chuyển sang NAT Instance hoặc mua Savings Plan |

---

## 3. Cost optimization applied

### 3.1 Đã áp dụng trong thiết kế hạ tầng

- [x] **VPC Gateway Endpoints cho S3 & DynamoDB**: Chuyển hướng lưu lượng truy cập nội bộ trực tiếp trên hạ tầng AWS, giảm thiểu data processing qua NAT Gateway, tiết kiệm ~$15-20/tháng.
- [x] **Event-driven Prediction Worker**: Worker chỉ hoạt động khi có trigger từ EventBridge Scheduler, tránh lãng phí compute nhàn rỗi (idle Fargate tasks), tiết kiệm ~$10/tháng.
- [x] **DynamoDB On-Demand Billing**: Không đặt trước dung lượng (provisioned capacity), chỉ trả phí dựa trên số lần ghi thực tế của Audit Log (cực kỳ rẻ cho tần suất 5 phút/lần).
- [x] **Timestream Magnetic Tiering**: Cấu hình Memory store ngắn hạn (7 ngày) và tự động đẩy dữ liệu cũ sang Magnetic store giúp tối ưu chi phí lưu trữ chuỗi thời gian.
- [x] **CloudWatch Log Retention (14 ngày)**: Giới hạn thời gian lưu trữ log thay vì lưu vô hạn để tránh phình chi phí lưu trữ CloudWatch Logs.
- [x] **Tối ưu hóa số lượng Custom Metrics**: Hạn chế số lượng custom metric gửi lên CloudWatch ở mức tối thiểu cần thiết (~6 metrics/service) để tránh "bẫy chi phí" của CloudWatch ($0.30/metric/tháng).

### 3.2 Không áp dụng (và lý do)

- [ ] **Fargate Spot Instances**: Không áp dụng cho Telemetry API để đảm bảo độ sẵn sàng dịch vụ (SLO Availability $\ge$ 99.5%).
- [ ] **Reserved Capacity / Savings Plans**: Không áp dụng do thời gian thử nghiệm Capstone ngắn (2 tuần), không đủ điều kiện cam kết tối thiểu 1 năm của AWS.
- [ ] **Bedrock Prompt Caching**: Hệ thống chạy statistical ML cục bộ trên ECS Fargate của nhóm AI, không gọi API Generative AI (Bedrock) nên tính năng này không khả dụng.

---

## 4. Cost vs alternatives (cùng task force TF4)

| Angle | $/tenant/month (50 tenant) | Trade-off chính |
|---|---|---|
| **CDO 04 — TSDB-backed Control Plane** (nhóm này) | **~$3.59** | Dữ liệu Timestream tính phí minh bạch, rẻ ở quy mô nhỏ. Rủi ro chi phí nằm ở NAT Gateway cố định. |
| **CDO khác — Lakehouse angle** (S3 + Athena) | ~$5.00 – $8.00 | S3 rẻ nhưng Athena tính phí theo dung lượng quét dữ liệu (data scan) của mỗi câu truy vấn. Khó kiểm soát chi phí nếu truy vấn nhiều và latency cao. |
| **CDO khác — Managed Observability** (Prometheus/Grafana) | ~$6.00 – $10.00 | Tốn chi phí vận hành, cài đặt cấu hình VM (EC2) chạy Prometheus liên tục 24/7 và bản quyền Grafana Cloud. |

---

## 5. 2-week capstone budget estimate

Dưới đây là dự báo chi phí thực tế cho **2 tuần chạy thử nghiệm Capstone** (môi trường Staging/Demo):

| Service | Forecast 2 tuần | Ghi chú |
|---|---|---|
| ECS Fargate (API + Worker) | ~$10.00 | Always-on API (0.25 vCPU) + event-driven Worker |
| NAT Gateway | ~$21.50 | Chi phí cố định theo giờ chạy thực tế của NAT |
| Amazon Timestream | ~$1.50 | Gồm ghi dữ liệu, lưu trữ và truy vấn |
| DynamoDB | ~$0.15 | On-demand cho Audit Log |
| CloudWatch | ~$4.50 | Gồm logs ingestion và Dashboard |
| S3 & Khác | ~$0.50 | Terraform state và CI/CD artifacts |
| **Total forecast 2 tuần** | **~$38.15** | Còn dư **~$161.85** trong ngân sách $200 để chạy load test |

### 5.1 Measured actual (Pack #2 — fill in W12)

| Service | Forecast | Actual | Delta |
|---|---|---|---|
| ECS Fargate | $10.00 | - | - |
| NAT Gateway | $21.50 | - | - |
| Timestream | $1.50 | - | - |
| DynamoDB | $0.15 | - | - |
| CloudWatch | $4.50 | - | - |
| Khác | $0.50 | - | - |
| **Total** | **$38.15** | **-** | **-** |

### 5.2 Per-tenant actual (Pack #2 — fill in W12)

| Tenant test | Service | $/day forecast | Extrapolate $/month |
|---|---|---|---|
| Tenant-1 | `payment-gateway` | ~$0.70 | ~$21 |
| Tenant-2 | `ledger-service` | ~$0.70 | ~$21 |
| Tenant-3 | `kyc-worker` | ~$0.70 | ~$21 |

### 5.3 Cost-per-correct-decision (Pack #2 — joint with AI eval)

| Metric | Forecast | Actual |
|---|---|---|
| Total prediction calls trong capstone | ~3,456 (8,640 × 2 tuần / 5) | - |
| Correct decisions (catch ≥80%) | ~2,765 | - |
| Total platform cost | ~$38.15 | - |
| **Cost per correct decision** | **~$0.013** | **-** |

---

## 6. Cost guardrails

### 6.1 Ngưỡng cảnh báo chi phí (70/90/100 Policy)

*Quy tắc cốt lõi*: **Không bao giờ tắt Audit Log (DynamoDB) và cơ chế Fail-open Fallback** ở bất kỳ ngưỡng chi phí nào để đảm bảo hệ thống không mất hoàn toàn giám sát.

*   **Ngưỡng 70% ($140/tháng)**: Bắn cảnh báo qua SNS tới Email/Slack của Infra Owner. Rà soát tần suất gọi AI của Worker, đảm bảo không tự ý giảm cadence xuống dưới 5 phút/lần.
*   **Ngưỡng 90% ($180/tháng)**: Review khẩn cấp. Tự động giảm log verbosity (chuyển từ `DEBUG` sang `WARN`) để giảm chi phí ghi log của CloudWatch. Rà soát lại Timestream query pattern, đảm bảo query bắt buộc phải filter theo `tenant_id`, `service_id` và time window. Giảm tần suất chạy kịch bản load test giả lập.
*   **Ngưỡng 100% ($200/tháng)**: Kích hoạt **Circuit Breaker** – lập tức tạm dừng (pause) toàn bộ luồng chạy Synthetic Load Test (k6/Locust) và các prediction job không quan trọng. Chuyển hoàn toàn sang theo dõi bằng ngưỡng tĩnh (CloudWatch alarms) để duy trì giám sát tối thiểu.

### 6.2 Cấu hình Terraform Budgets

```hcl
resource "aws_budgets_budget" "platform_budget" {
  name         = "tf4-cdo04-platform-budget"
  budget_type  = "COST"
  limit_amount = "200"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 70
    threshold_type      = "PERCENTAGE"
    notification_type   = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }

  notification {
    comparison_operator = "GREATER_THAN"
    threshold           = 90
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

## 7. Cost recommendations for production

*   **Thay thế NAT Gateway bằng NAT Instance**: Sử dụng 1 EC2 instance siêu nhỏ (ví dụ `t3.nano` hoặc `t4g.nano`) tự cấu hình NAT thay vì AWS NAT Gateway dịch vụ. Chi phí sẽ giảm từ **$43.07/tháng** xuống chỉ còn **~$3.50/tháng** (tiết kiệm hơn 90% chi phí NAT).
*   **AWS Savings Plans**: Đăng ký gói cam kết sử dụng Compute 1 năm cho Fargate để giảm 20-30% chi phí.
*   **Chuyển đổi sang DynamoDB Provisioned Capacity**: Khi lượng truy cập đã ổn định và dự đoán được, chuyển DynamoDB sang Provisioned Capacity và cấu hình Auto-scaling để tiết kiệm chi phí hơn On-demand.

---

## Related documents

*   [`02_infra_design.md`](02_infra_design.md) — Sơ đồ kiến trúc hạ tầng chi tiết.
*   [`04_deployment_design.md`](04_deployment_design.md) — Kế hoạch CI/CD và triển khai.
*   [`07_test_eval_report.md`](07_test_eval_report.md) — Báo cáo test tải kiểm chứng giả định chi phí.
*   [`08_adrs.md`](08_adrs.md) — ADR-002 (Timestream) và ADR-003 (DynamoDB on-demand).
