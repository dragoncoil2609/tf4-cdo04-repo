<!--
TASK: CPOA-104 | CDO-W12-067 - Cost guard runbook
OWNER: Tạ Hoàng Huy

DESCRIPTION:
SRE Runbook phản ứng nhanh kiểm soát ngân sách $200 cho nền tảng CDO-04.
Định nghĩa các bước xử lý tại mốc 50% ($100), 80% ($160) và 100% ($200) budget.
-->

# Cost Guard Runbook & Incident Response — CDO-04

Tài liệu này hướng dẫn SRE phản ứng khi AWS Budgets hoặc SNS Topic `budget_alert` báo vượt ngưỡng chi phí. Policy final của CDO-04:

```text
50%  -> alert only
80%  -> alert + manual review/runbook
100% -> emergency breaker scale down only prediction-worker + ai-engine
```

`telemetry-api` phải tiếp tục chạy để giữ `/health` và ingest path. Không tắt DynamoDB audit, SQS/DLQ, AMP, SNS, CloudWatch hoặc S3 failure buffer bằng cost breaker.

---

## 1. Mốc 50% Ngân sách ($100/tháng)

Cảnh báo này chỉ để phát hiện sớm bất thường. Không scale service tự động.

### Các bước kiểm tra

1. **Rà soát lịch Load Test**
   - Kiểm tra có ai đang chạy k6 benchmark, drift test hoặc soak test ngoài khung giờ quy định không.
   - Nếu có, yêu cầu dừng hoặc giảm synthetic load về test window đã duyệt.
2. **Kiểm tra CloudWatch Logs**
   - Kiểm tra log volume của `telemetry-api`, `prediction-worker`, `ai-engine`.
   - Nếu DEBUG/INFO quá nhiều, tạo ticket chuyển về `WARN` ở batch vận hành tiếp theo.
3. **Kiểm tra AMP cardinality**
   - Chạy PromQL để ước lượng active series:
     ```promql
     count({__name__=~".+"})
     ```
   - Nếu active series tăng đột biến, tìm metric nhiều label nhất:
     ```promql
     topk(5, count by (__name__) ({__name__=~".+"}))
     ```
   - Kiểm tra không có label động như `request_id`, `trace_id`, `user_id`, `prediction_id`.

---

## 2. Mốc 80% Ngân sách ($160/tháng)

Cảnh báo này yêu cầu manual review. Không scale service tự động.

### Các bước xử lý

1. **Freeze prediction cadence ở 5 phút**
   - Không giảm EventBridge Scheduler xuống 1 phút.
   - Không tăng số service/tenant synthetic ngoài scope demo.
2. **Giảm optional spend thủ công**
   - Dừng hoặc giảm k6/synthetic load.
   - Giảm log verbosity về `WARN` trong task definition ở lần deploy tiếp theo.
   - Review PromQL scoping: mọi query phải filter `tenant_id`, `service_id`, metric name và range 120 phút.
3. **Tạo cost review note**
   - Ghi lại nguyên nhân nghi ngờ: log volume, synthetic load, AMP active series, ECS task count, NAT data.
   - Không thay đổi desired count của `telemetry-api`, `prediction-worker`, `ai-engine` ở mốc 80% nếu chưa có approval.

---

## 3. Mốc 100% Ngân sách ($200/tháng)

Mốc Critical. Cost breaker được phép scale down compute tốn kém nhưng không phá ingest/audit foundation.

### Expected breaker behavior

```text
scale down:
  - tf4-cdo04-<env>-prediction-worker -> desired_count = 0
  - tf4-cdo04-<env>-ai-engine         -> desired_count = 0

keep running:
  - tf4-cdo04-<env>-telemetry-api
  - SQS/DLQ
  - DynamoDB audit/policy
  - AMP workspace
  - S3 failure buffer/evidence
  - SNS/CloudWatch
```

### Quy trình xác nhận

1. **Xác nhận alert**
   - Kiểm tra email/SNS có tiêu đề tương đương `CRITICAL: CDO Platform Cost Limit Reached`.
   - Kiểm tra CloudWatch Logs của Lambda cost breaker.
2. **Xác nhận target scope**
   ```bash
   aws ecs describe-services \
     --cluster tf4-cdo04-sandbox-cluster \
     --services tf4-cdo04-sandbox-prediction-worker tf4-cdo04-sandbox-ai-engine tf4-cdo04-sandbox-telemetry-api \
     --query "services[].{Service:serviceName,Desired:desiredCount,Running:runningCount}"
   ```
   - `prediction-worker` = 0 desired.
   - `ai-engine` = 0 desired.
   - `telemetry-api` vẫn >= 1 desired.
3. **Ghi incident note**
   - Lưu timestamp, Budget event, Lambda log link, ECS desired counts trước/sau.

---

## 4. Rollback sau breaker

Chỉ rollback khi cycle chi phí mới bắt đầu hoặc owner phê duyệt tăng budget.

```bash
aws ecs update-service \
  --cluster tf4-cdo04-sandbox-cluster \
  --service tf4-cdo04-sandbox-ai-engine \
  --desired-count 2

aws ecs update-service \
  --cluster tf4-cdo04-sandbox-cluster \
  --service tf4-cdo04-sandbox-prediction-worker \
  --desired-count 1
```

Sau rollback:

1. Kiểm tra ECS service stable.
2. Kiểm tra SQS/DLQ depth trước khi bật lại worker ở môi trường nhiều test message.
3. Nếu cần dọn test messages, purge queue/DLQ theo quy trình test-window, không purge production queue nếu chưa có approval.
4. Ghi lại evidence rollback vào final QA report.
