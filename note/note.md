# SLO Early-Warning Control Plane - Notes

🏥 1. Mục tiêu cốt lõi của App
Giám sát 3 dịch vụ Tier-1 đại diện cho 3 dạng quá tải tài nguyên:
*   **payment-gateway** (quá tải ALB/RDS - do traffic spike).
*   **ledger-service** (quá tải kết nối/truy vấn DB Aurora - do DB connection utilization).
*   **kyc-worker** (quá tải hàng đợi - do SQS queue depth và worker timeout).

Đưa ra cảnh báo sớm trước khi vi phạm SLO ít nhất 15 phút (Target là 30 phút) với tỷ lệ báo giả (False Positive) $\le$ 12%.

⚙️ 2. Luồng hoạt động từng bước (Step-by-Step Workflow)
Hạ tầng nền tảng được host trên cụm ECS Fargate, phối hợp với các dịch vụ Serverless của AWS hoạt động theo chu trình khép kín sau:

*   **Bước 1: Thu thập số liệu (Telemetry Ingestion)**
    Telemetry Ingestion API nhận dữ liệu metric (CPU, latency, connection utilization, queue depth,...) từ 3 dịch vụ demo và đẩy trực tiếp vào Amazon Timestream (Cơ sở dữ liệu chuỗi thời gian - TSDB).
*   **Bước 2: Lập lịch Dự báo (Prediction Orchestration)**
    Cứ mỗi 5 phút/lần (Balanced Mode), EventBridge Scheduler kích hoạt gửi một tin nhắn yêu cầu dự báo vào hàng đợi SQS (để đảm bảo không bị mất job và hỗ trợ scale worker khi tải tăng).
*   **Bước 3: Lấy dữ liệu & Gọi AI (Prediction Worker)**
    Prediction Worker nhận job từ SQS, thực hiện truy vấn dữ liệu metric lịch sử từ 1 đến 2 giờ gần nhất trong Amazon Timestream làm dữ liệu đầu vào.
    Worker gọi endpoint của AI Engine (POST /v1/predict) để AI phân tích và dự báo rủi ro.
*   **Bước 4: Xử lý Kết quả & Dự phòng (Decision & Fallback)**
    *   Nếu AI hoạt động bình thường: AI sẽ trả về mức độ rủi ro (risk_level), nguyên nhân (root_cause), và khuyến nghị hành động cụ thể (recommendation - ví dụ: Tăng worker kyc từ 20 lên 40).
    *   Nếu AI bị sập/timeout: Hệ thống tự động kích hoạt Fail-open Fallback, chuyển sang kiểm tra bằng các ngưỡng tĩnh (static thresholds) được thiết lập sẵn trên CloudWatch để không bị mất hoàn toàn khả năng giám sát.
*   **Bước 5: Ghi chép lịch sử (Audit Log)**
    Mỗi lượt gọi dự báo (kể cả lượt gọi AI thành công hay lượt tự động kích hoạt fallback) đều được mã hóa và ghi lại thành một bản ghi Audit Log lưu trữ trong DynamoDB với thời gian lưu trữ (retention) 90 ngày.
*   **Bước 6: Phát cảnh báo kèm Chứng cứ (SNS Alert & Evidence)**
    Nếu phát hiện rủi ro cao (high risk), hệ thống gửi cảnh báo qua Amazon SNS (email/Slack webhook) tới các kỹ sư SRE.
    Cảnh báo đi kèm Chứng cứ 3 lớp (Evidence) để SRE kiểm chứng trước khi phê duyệt khuyến nghị hành động:
    *   *Metric evidence*: Link tham chiếu truy vấn dữ liệu gốc trong Timestream.
    *   *Visualization evidence*: Link biểu đồ tương ứng trên CloudWatch Dashboard.
    *   *Decision evidence*: Mã ID lưu trữ quyết định dự báo trong DynamoDB Audit Log.

💰 3. Cơ chế Quản lý chi phí (Cost Guard)
Vì hệ thống phải chạy 24/7 dưới ngân sách $200/tháng, ứng dụng tích hợp sẵn cơ chế tự động ngắt tải thử nghiệm:
*   Nếu chi phí AWS đạt 80%: Review lại tần suất log và giảm bớt các kịch bản test tải.
*   Nếu chi phí AWS đạt 100%: Tạm dừng chạy thử nghiệm tải giả lập (synthetic workload) hoặc các job dự đoán không quan trọng để bảo vệ chi phí, nhưng không bao giờ tắt luồng Audit Log và luồng Fallback.
