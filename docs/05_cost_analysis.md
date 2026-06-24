# Cost Analysis - Task Force 4 · CDO 04

<!-- Doc owner: Tạ Hoàng Huy (Huy)
     Status: Refined (W11 T6 Pack #1) - v1.3
     Word target: 1000-1500 từ -->

> **Scope note**: Platform của nhóm không dùng LLM/Bedrock. AI Engine (Nhóm AI) chạy statistical ML.
> Cost "AI inference" trong doc này = data transfer CDO→AI endpoint + Fargate compute của Prediction Worker,
> không phải per-token LLM cost. Điều này là điểm khác biệt cốt lõi so với template mặc định.

---

## 1. Cost model per monitored service unit (forecast)

> **Định nghĩa "monitored service unit" trong TF4**: một service được monitor (ví dụ `payment-gateway`) với per-service
> baseline riêng biệt. Capstone demo với 3 monitored service units. Production scale = số service tier-1 được onboard.

### 1.1 Shared fixed cost (platform-level, amortized)

Chi phí này tồn tại độc lập với số lượng monitored service unit và được chia đều cho toàn bộ hệ thống:

| Component | AWS Service | Config | $/month (fixed) |
|---|---|---|---|
| Telemetry API | ECS Fargate | 0.25 vCPU · 0.5GB RAM · always-on | ~$9.01 |
| Prediction Worker | ECS Fargate | 0.25 vCPU · 0.5GB RAM · event-driven (Giả định chạy demo/test window tổng thời gian thực tế khoảng 150 giờ/tháng) | ~$5.00 |
| NAT Gateway | VPC | 1 NAT · ap-southeast-1 (Singapore) | ~$43.07 |
| CloudWatch Dashboard | CloudWatch | 1 dashboard dùng chung | ~$3.00 |
| EventBridge Scheduler | Scheduler | ~8,640 invocations/tháng/3 service | ~$0.01 |
| **Total fixed** | | | **~$60.09/month** |

> **Lưu ý về Prediction Worker**: Worker chạy dưới dạng ECS Fargate task được kích hoạt bởi EventBridge Scheduler qua SQS. Chi phí $5.00/tháng dựa trên giả định chạy theo event-driven (khoảng 150 giờ/tháng cho demo/test window). Nếu chạy always-on 24/7 trong Production thực tế, chi phí sẽ tăng lên tương đương Telemetry API (~$9.01/tháng).

> **Lưu ý NAT Gateway**: $43.07/tháng (tính theo đơn giá $0.059/giờ tại Singapore) là chi phí cố định lớn nhất, chiếm hơn 70% tổng chi phí cố định. MVP sử dụng 1 NAT Gateway kết hợp với S3/DynamoDB Gateway Endpoints để giảm một phần chi phí NAT data processing, chứ không bypass hoàn toàn NAT Gateway.

### 1.2 Variable cost per monitored service unit (per service monitored)

| Component | AWS Service | Unit cost | Avg usage/month | $/monitored-service-unit/month |
|---|---|---|---|---|
| Metric ingest | Amazon Timestream (write) | $0.62/million writes | ~51,840 writes (1 write/5 phút × 6 metric × 30 ngày) | ~$0.03 |
| Metric storage | Amazon Timestream (magnetic) | $0.0036/GB-month | ~0.5 GB | ~$0.002 |
| Prediction query | Amazon Timestream (query) | $0.01/GB scanned | ~8 GB scanned (8,640 queries × ~1MB/query) | ~$0.08 |
| Audit log write | DynamoDB (on-demand) | $1.25/million WCU | ~8,640 writes | ~$0.01 |
| Audit log storage | DynamoDB | $0.25/GB-month | ~0.3 GB | ~$0.08 |
| CloudWatch logs | CloudWatch | $0.50/GB ingested | ~0.5 GB app log/service | ~$0.25 |
| CloudWatch metrics | CloudWatch | $0.30/metric/month | ~6 custom metric/service (giới hạn tối ưu) | ~$1.80 |
| SNS alert | SNS | Mức cơ bản | <1,000 notifications | ~$0.00 |
| SQS (prediction queue) | SQS | $0.40/million requests | ~17,280 messages | ~$0.01 |
| AI endpoint call | Data transfer internal | ~$0 (VPC-internal) | 8,640 calls | ~$0.00 |
| **Total variable / monitored-service-unit / month** | | | | **~$2.26** |

### 1.3 Total per-monitored-service-unit cost (platform amortized)

| Monitored service unit count | Fixed cost/month | Variable/month | **Total/month** | **Per-service-unit** |
|---|---|---|---|---|
| 3 (capstone demo) | $60.09 | $6.78 | **$66.87** | **$22.29** |
| 10 | $60.09 | $22.60 | **$82.69** | **$8.27** |
| 50 | $60.09 | $113.00 | **$173.09** | **$3.46** |

---

## 2. Cost at scale

### 2.1 Assumptions for scale estimate (Các giả định tính toán quy mô)
Để đưa ra các dự báo chi phí dưới đây, nhóm CDO tuân thủ các giả định thực tế sau:
- **Số lượng metrics**: Giới hạn ở mức 6 metrics/service.
- **Cadence**: Tần suất lấy mẫu và gọi dự đoán là 5 phút/lần.
- **Dung lượng log**: Thấp (low log volume, dưới 0.5 GB/service/tháng).
- **Phạm vi giao diện**: Không triển khai toàn bộ các endpoint giao diện phức tạp (no full interface endpoints), chỉ tập trung vào telemetry ingestion API và prediction worker.
- **Mô hình AI**: Không sử dụng mô hình LLM/Bedrock (chỉ chạy ML thống kê).

### 2.2 Dự báo chi phí theo quy mô

| Monitored service unit count | Monthly total | Avg per-service-unit | Ghi chú |
|---|---|---|---|
| 3 | ~$67 | ~$22.29 | Môi trường Capstone Demo — fixed cost chưa được phân bổ tối ưu |
| 10 | ~$83 | ~$8.27 | Quy mô sản xuất nhỏ (Small Production) |
| 50 | ~$173 | ~$3.46 | Quy mô mục tiêu (Production Target) — vẫn nằm dưới budget $200 |
| 100 | ~$286 | ~$2.86 | Vượt budget $200 — cần cấu hình NAT Instance cho sandbox hoặc mua Savings Plan |

*Per-service-unit cost giảm dần khi quy mô tăng vì fixed cost ($60.09) được phân bổ đều cho nhiều service unit hơn. Từ 50 service units trở lên, variable cost bắt đầu chiếm ưu thế.*

---

## 3. Cost optimization applied

### 3.1 Đã áp dụng trong thiết kế hạ tầng

- [x] **Gateway Endpoints cho S3 & DynamoDB**: MVP sử dụng 1 NAT Gateway kết hợp với S3/DynamoDB Gateway Endpoints để chuyển hướng một phần lưu lượng nội bộ trực tiếp trên hạ tầng AWS. Điều này giúp giảm thiểu một phần chi phí NAT data processing (mức tiết kiệm cụ thể sẽ được xác nhận sau khi có hóa đơn thực tế - actual bill ở Pack #2).
- [x] **Event-driven Prediction Worker**: Worker chỉ hoạt động khi có trigger từ EventBridge Scheduler qua SQS, tránh lãng phí compute nhàn rỗi (idle Fargate tasks).
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

| Angle | $/monitored-service-unit/month (50 units) | Trade-off chính |
|---|---|---|
| **CDO 04 — TSDB-backed Control Plane** (nhóm này) | **~$3.46** | Dữ liệu Timestream tính phí minh bạch, rẻ ở quy mô nhỏ. Rủi ro chi phí nằm ở NAT Gateway cố định. |
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

### 5.2 Per-monitored-service-unit actual (Pack #2 — fill in W12)

| Monitored service unit test | Service | $/day forecast | Extrapolate $/month |
|---|---|---|---|
| Unit-1 | `payment-gateway` | ~$0.70 | ~$21 |
| Unit-2 | `ledger-service` | ~$0.70 | ~$21 |
| Unit-3 | `kyc-worker` | ~$0.70 | ~$21 |

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

*   **Ngưỡng 70% ($140/tháng)**: Bắn cảnh báo qua SNS tới Email/Slack của Infra Owner. Rà soát tần suất gọi AI của Worker, đảm bảo không cho phép tăng prediction cadence dày hơn 5 phút/lần nếu chưa có approval.
*   **Ngưỡng 90% ($180/tháng)**: Review khẩn cấp. Tự động giảm log verbosity (chuyển từ `DEBUG` sang `WARN`) để giảm chi phí ghi log của CloudWatch. Rà soát lại Timestream query pattern, đảm bảo câu truy vấn bắt buộc phải filter đầy đủ theo `tenant_id`, `service_id`, `metric_type` và time window (align với ADR-004). Giảm tần suất chạy kịch bản load test giả lập.
*   **Ngưỡng 100% ($200/tháng)**: Kích hoạt **Circuit Breaker** – lập tức tạm dừng (pause) toàn bộ luồng chạy Synthetic Load Test (k6/Locust) và các prediction job không quan trọng. Các prediction/fallback decision quan trọng vẫn tiếp tục được ghi audit. Cơ chế fail-open static threshold fallback không bị tắt.

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

### 6.3 Per-monitored-service-unit quota enforcement

- API entry layer rate limit: 1,000 req/min per monitored service unit (đây là giả định thiết kế - assumption cho W12, được enforced tại Telemetry API)
- Prediction cadence lock: không cho phép caller request prediction dày hơn 5 phút/lần per service
- Timestream write quota: reject ingest nếu write rate > 2× baseline expected per monitored service unit (để đảm bảo tối ưu hóa chi phí và align với ADR-004)

---

## 7. Cost recommendations for production

*   **Sử dụng NAT Instance (Tùy chọn - Optional)**: Sử dụng 1 EC2 instance siêu nhỏ (ví dụ `t3.nano` hoặc `t4g.nano`) tự cấu hình NAT thay vì AWS NAT Gateway dịch vụ. Đây là tùy chọn (optional) dành riêng cho môi trường non-production hoặc cost-sensitive sandbox để tiết kiệm chi phí, không khuyến nghị làm mặc định cho môi trường Production thực tế nhằm đảm bảo tính sẵn sàng cao (High Availability) và thông lượng mạng lớn.
*   **AWS Savings Plans**: Đăng ký gói cam kết sử dụng Compute 1 năm cho Fargate để giảm 20-30% chi phí.
*   **Chuyển đổi sang DynamoDB Provisioned Capacity**: Khi lượng truy cập đã ổn định và dự đoán được, chuyển DynamoDB sang Provisioned Capacity và cấu hình Auto-scaling để tiết kiệm chi phí hơn On-demand.

---

## Related documents

*   [`02_infra_design.md`](02_infra_design.md) — Sơ đồ kiến trúc hạ tầng chi tiết.
*   [`04_deployment_design.md`](04_deployment_design.md) — Kế hoạch CI/CD và triển khai.
*   [`07_test_eval_report.md`](07_test_eval_report.md) — Báo cáo test tải kiểm chứng giả định chi phí.
*   [`08_adrs.md`](08_adrs.md) — Hồ sơ quyết định kiến trúc: ADR-004 (Timestream), ADR-007 (DynamoDB audit store), và ADR-008 (NAT + Gateway Endpoints).
