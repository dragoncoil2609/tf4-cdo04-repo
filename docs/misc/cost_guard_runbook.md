<!--
TASK: CPOA-104 | CDO-W12-067 - Cost guard runbook
OWNER: Tạ Hoàng Huy

DESCRIPTION:
SRE Runbook phản ứng nhanh kiểm soát ngân sách $200 cho nền tảng CDO-04.
Định nghĩa các bước xử lý tại mốc 50% ($100), 80% ($160) và 100% ($200) budget.
-->

# Cost Guard Runbook & Incident Response — CDO-04

Tài liệu này hướng dẫn đội ngũ SRE của nhóm CDO-04 thực hiện kiểm tra và phản ứng nhanh khi nhận được cảnh báo vượt ngưỡng chi phí từ AWS Budgets hoặc SNS Topic `budget_alert`.

---

## 1. Mốc Cảnh báo 50% Ngân sách ($100/tháng)

Cảnh báo này chủ yếu mang tính chất thông tin và phát hiện sớm các dị thường về lượng tải.

### Các bước kiểm tra:
1. **Rà soát lịch trình Load Test**:
   * Kiểm tra xem có thành viên nào trong nhóm đang chạy test tải (k6 benchmark) hoặc test drift ngoài khung giờ quy định hay không.
   * Nếu có, yêu cầu dừng ngay các bài test dài hạn (chỉ được test spike 2-3 phút).
2. **Kiểm tra Cardinality và Active Series trên Amazon Managed Prometheus (AMP)**:
   * Truy cập query console của AMP và chạy câu lệnh PromQL sau để đếm tổng số active time-series đang được ingest:
     ```promql
     count({__name__=~".+"})
     ```
   * Nếu số lượng Active Series tăng đột biến (> 100,000 series), chạy truy vấn sau để tìm metric nào đang có nhiều label phân tán nhất:
     ```promql
     topk(5, count by (__name__) ({__name__=~".+"}))
     ```
   * Đảm bảo Telemetry API không bị lọt các dynamic label (như `request_id`, `user_id`) thông qua log của container `telemetry-api`.

---

## 2. Mốc Cảnh báo 80% Ngân sách ($160/tháng)

Cảnh báo ở mức **High Alert**. SRE bắt buộc phải can thiệp kỹ thuật ngay để giảm thiểu chi phí phát sinh trước khi chạm mốc $200.

### Các hành động bắt buộc:
1. **Giảm thiểu Ingest Logs (Cập nhật LOG_LEVEL=WARN)**:
   * Đội ngũ SRE chạy lệnh AWS CLI sau để tăng mức độ lọc logs của ECS Fargate tasks. Việc này giúp giảm cước phí ghi log lên CloudWatch Logs:
     ```bash
     # Cập nhật LOG_LEVEL cho Telemetry API
     aws ecs update-service \
       --cluster tf4-cdo04-sandbox-cluster \
       --service tf4-cdo04-sandbox-telemetry-api \
       --force-new-deployment
     ```
     *(Lưu ý: Đảm bảo biến môi trường `LOG_LEVEL` trong Task Definition đã được cập nhật thành `WARN` để container lọc bỏ log INFO/DEBUG).*
2. **Khóa cứng Cadence Dự báo (Prediction Cadence)**:
   * Khóa cứng thời gian chạy của Prediction Worker ở mức **5 phút/lần** (cadence của Balanced Mode).
   * Tuyệt đối không được chỉnh sửa EventBridge Scheduler xuống tần suất 1 phút/lần trong giai đoạn này.

---

## 3. Mốc Cảnh báo 100% Ngân sách ($200/tháng)

Mốc **Critical**. Nền tảng sẽ tự động kích hoạt **Cost Circuit Breaker** thông qua AWS Lambda để chặn đứng việc phát sinh chi phí.

### Quy trình xác nhận và ứng phó:
1. **Xác nhận trạng thái Circuit Breaker**:
   * Kiểm tra hòm thư email của SRE xem có nhận được email tiêu đề `CRITICAL: CDO Platform Cost Limit Reached - Circuit Breaker Activated` hay không.
   * Kiểm tra CloudWatch Logs của Lambda function `/aws/lambda/tf4-cdo04-cost-breaker-sandbox`.
2. **Kiểm tra trạng thái ECS Fargate tasks**:
   * Sử dụng lệnh CLI sau để xác nhận cả 2 services `prediction-worker` and `ai-engine` đã được scale về **0 tasks**:
     ```bash
     aws ecs describe-services \
       --cluster tf4-cdo04-sandbox-cluster \
       --services tf4-cdo04-sandbox-prediction-worker tf4-cdo04-sandbox-ai-engine \
       --query "services[].{Service:serviceName, Desired:desiredCount, Running:runningCount}"
     ```
   * Đảm bảo service `telemetry-api` vẫn hoạt động bình thường (Desired = 2) để không làm mất các metrics của client gửi về.

---

## 4. Quy trình Dọn dẹp sau khi Test (Post-Test Cleanup Runbook)

Sau khi hoàn tất đợt chạy test tải hoặc test drift, SRE cần dọn dẹp hàng đợi và phục hồi hệ thống để tránh tình trạng "Poison Message Loop" khi kích hoạt lại hệ thống.

### Các bước dọn dẹp bắt buộc:
1. **Xóa sạch (Purge) SQS Queue**:
   * Trước khi scale-up lại hệ thống, bắt buộc phải xóa sạch các bản tin test còn tồn đọng trong queue để tránh Prediction Worker bị quá tải ngay khi vừa khởi động lại. Chạy câu lệnh:
     ```bash
     # Purge hàng đợi chính
     aws sqs purge-queue --queue-url https://sqs.us-east-1.amazonaws.com/<ACCOUNT_ID>/tf4-cdo04-prediction-sandbox
     
     # Purge hàng đợi lỗi (DLQ)
     aws sqs purge-queue --queue-url https://sqs.us-east-1.amazonaws.com/<ACCOUNT_ID>/tf4-cdo04-prediction-dlq-sandbox
     ```
2. **Khôi phục (Scale-up) hệ thống**:
   * Khi chu kỳ tính cước mới bắt đầu hoặc ngân sách được phê duyệt nâng thêm, khôi phục lại mong muốn hoạt động của các service:
     ```bash
     # Khôi phục AI Engine về 2 tasks
     aws ecs update-service \
       --cluster tf4-cdo04-sandbox-cluster \
       --service tf4-cdo04-sandbox-ai-engine \
       --desired-count 2
     
     # Khôi phục Prediction Worker về 1 task
     aws ecs update-service \
       --cluster tf4-cdo04-sandbox-cluster \
       --service tf4-cdo04-sandbox-prediction-worker \
       --desired-count 1
     ```
