# SLO Early-Warning Control Plane - Notes

## 🏥 1. Mục tiêu cốt lõi của App
Giám sát 3 dịch vụ Tier-1 đại diện cho 3 dạng quá tải tài nguyên chính:
*   **payment-gateway**: Quá tải ALB/RDS do lượng truy cập đột biến (traffic spike).
*   **ledger-service**: Quá tải kết nối/truy vấn Database Aurora (DB connection utilization).
*   **kyc-worker**: Quá tải hàng đợi (SQS queue depth và worker timeout).

> [!IMPORTANT]
> Mục tiêu chính của hệ thống là đưa ra cảnh báo sớm trước khi xảy ra vi phạm SLO ít nhất **15 phút** (mục tiêu tối ưu là **30 phút**) với tỷ lệ báo động giả (False Positive) $\le$ **12%**.

---

## ⚙️ 2. Luồng hoạt động từng bước (Step-by-Step Workflow)
Hạ tầng nền tảng được vận hành trên cụm dịch vụ ECS Fargate kết hợp với các tài nguyên Serverless của AWS tạo thành một chu trình khép kín gồm 6 bước:

### 📥 Bước 1: Thu thập số liệu (Telemetry Ingestion)
Telemetry Ingestion API tiếp nhận các gói dữ liệu metric (CPU, latency, connection utilization, queue depth,...) từ 3 dịch vụ demo và ghi dữ liệu trực tiếp vào **Amazon Managed Service for Prometheus (AMP)**.

### 📅 Bước 2: Lập lịch Dự báo (Prediction Orchestration)
Định kỳ **5 phút một lần** (chế độ Balanced Mode), **EventBridge Scheduler** sẽ tự động gửi một tin nhắn yêu cầu phân tích tải vào hàng đợi **SQS** nhằm đảm bảo không bị mất lượt dự đoán và sẵn sàng scale worker khi hệ thống tải tăng cao.

### 🧠 Bước 3: Lấy dữ liệu & Gọi AI (Prediction Worker)
Dịch vụ **Prediction Worker** thực hiện việc đọc tin nhắn SQS, sau đó:
*   Truy vấn ngược lại dữ liệu metric lịch sử từ **1 đến 2 giờ gần nhất** từ **AMP** bằng ngôn ngữ PromQL.
*   Gọi endpoint của **AI Engine** (`POST /v1/predict`) làm dữ liệu đầu vào cho mô hình AI phân tích rủi ro.

### 🛡️ Bước 4: Xử lý Kết quả & Dự phòng (Decision & Fallback)
*   **Kịch bản bình thường:** AI phân tích thành công và trả về thông tin mức độ rủi ro (`risk_level`), nguyên nhân gốc rễ (`root_cause`) và đề xuất hành động cụ thể (`recommendation` - ví dụ: *tăng lượng kyc-worker từ 20 lên 40*).
*   **Kịch bản dự phòng (Fallback) (CPOA-72):** Nếu AI Engine bị sập hoặc gặp sự cố quá thời gian phản hồi (timeout), hệ thống tự động kích hoạt chế độ **Static Threshold Fallback** bằng cách đọc các ngưỡng tĩnh được lưu trữ trong bảng **DynamoDB Service Policies** thay vì gọi AI Engine, giúp duy trì liên tục khả năng giám sát.

### 📝 Bước 5: Ghi nhật ký lịch sử (Audit Log)
Tất cả các cuộc gọi dự báo (dù AI trả kết quả thành công hay hệ thống phải chạy luồng fallback) đều được mã hóa dữ liệu và lưu lại thành một bản ghi nhật ký tại **DynamoDB Audit Table** với thời hạn lưu trữ tự động xóa sau **90 ngày**.

### 🚨 Bước 6: Phát cảnh báo kèm Chứng cứ (SNS Alert & Evidence)
Khi phát hiện nguy cơ quá tải mức độ cao (high risk), hệ thống sẽ gửi thông báo khẩn qua **Amazon SNS** (email hoặc Slack webhook) cho đội ngũ vận hành SRE. 
Thông báo đi kèm **Chứng cứ 3 lớp (Evidence)** để SRE kiểm chứng trước khi duyệt hành động:
1.  **Metric evidence:** Đường dẫn tham chiếu trực tiếp đến truy vấn dữ liệu gốc trong AMP.
2.  **Visualization evidence:** Đường dẫn xem biểu đồ trực quan tương ứng trên CloudWatch Dashboard.
3.  **Decision evidence:** Mã ID tham chiếu bản ghi tương ứng trong DynamoDB Audit Log.

---

## 👥 3. Các Use Case chính của Hệ thống (System Use Cases)

Hệ thống được thiết kế để giải quyết 5 bài toán/nghiệp vụ chính sau của vận hành:

### 🏷️ Use Case 1: Thu thập Metric & Kiểm soát dữ liệu rác (Telemetry Ingestion & Guardrails)
*   **Tác nhân:** Client (Synthetic load generator/k6) gửi dữ liệu đo lường.
*   **Mô tả:** Nhận dữ liệu tải qua endpoint công khai `/v1/ingest`. Telemetry API tự động chặn lọc các thuộc tính nhạy cảm (PII), chống phình to nhãn (Cardinality Guardrail) để bảo vệ Prometheus (AMP) khỏi nghẽn và phát sinh chi phí thừa.
*   **Luồng phụ:** Nếu ghi sang AMP lỗi, dữ liệu được chuyển tạm vào **S3 failure buffer** (lưu trữ phục hồi sau).

### 🔍 Use Case 2: Phân tích tải tự động định kỳ (Scheduled Prediction)
*   **Tác nhân:** EventBridge Scheduler gửi tin nhắn yêu cầu tự động.
*   **Mô tả:** Worker đọc tin nhắn từ SQS, lấy chuỗi dữ liệu 120 phút từ Prometheus, thực hiện thuật toán điền khuyết (Imputation) để làm mịn dữ liệu bị thiếu trước khi gửi qua Service Connect cho AI Engine chấm điểm khả năng quá tải (Anomalies).

### 🚨 Use Case 3: Cảnh báo khẩn & Cung cấp bằng chứng (SNS Alerting & Decision Audit)
*   **Tác nhân:** Prediction Worker khi phát hiện rủi ro cao từ AI Engine.
*   **Mô tả:** Tự động kích hoạt SNS gửi email/Slack báo động. Đồng thời, ghi chép đầy đủ chi tiết khuyến nghị và đường dẫn bằng chứng trực quan (Dashboard/PromQL/Audit ID) vào DynamoDB Audit để kỹ sư SRE nhanh chóng kiểm chứng.

### 🔄 Use Case 4: Kịch hoạt bộ lọc dự phòng tĩnh (Degradation Fallback)
*   **Tác nhân:** Prediction Worker khi AI Engine không phản hồi hoặc mất kết nối.
*   **Mô tả:** Hệ thống tự động chuyển sang cơ chế kiểm tra ngưỡng tĩnh trên CloudWatch (Fail-open) để đảm bảo không bị mù thông tin cảnh báo, đồng thời lưu trạng thái "degraded/fallback" vào DynamoDB.

### 📉 Use Case 5: Tự động ngắt tải bảo vệ ngân sách (Cost Guard & Cost Breaker)
*   **Tác nhân:** Lambda Cost Breaker khi nhận cảnh báo ngân sách AWS đạt 100%.
*   **Mô tả:** Tự động scale down số lượng task của AI Engine và Prediction Worker về `0` để lập tức dừng phát sinh chi phí chạy thử nghiệm, gửi cảnh báo SNS thông báo trạng thái đóng băng hệ thống.

---

## 🧪 6. Kịch bản kiểm thử tải k6 & Luồng Xác thực E2E (k6 Load Test Scenarios)

Hệ thống được cấu hình sẵn 4 kịch bản kiểm thử tải trọng thông qua công cụ **k6** để giả lập các dạng hành vi quá tải thực tế trên Staging/Sandbox:

| Kịch bản | Kịch bản kiểm thử k6 | Dịch vụ đích | Đặc trưng tải giả lập | Thời gian chạy | Đỉnh RPS (Peak) | Chỉ số giám sát chính |
|---|---|---|---|---|---|---|
| **SC-01** | `sc01_gradual_drift.js` | ledger | Tải tăng tịnh tiến (Ramp-up stages) | 45 phút | 1,500 RPS | `api_latency_ms`, `cpu_usage_percent`, `db_connection_pool_pct` |
| **SC-02** | `sc02_spike.js` | payment-gw | Tăng vọt đột biến (Constant-arrival) | 2 phút | 4,500 RPS | `api_latency_ms` |
| **SC-03** | `sc03_slow_leak.js` | ledger | Rò rỉ tài nguyên chậm (Soak constant-arrival) | 2 giờ | 800 RPS | `memory_usage_percent`, `active_connections`, `api_latency_ms` |
| **SC-04** | `sc04_noisy_baseline.js` | fraud-detector | Tải hình răng cưa nhiễu (Sawtooth arrival) | ~15 phút | 2,000 RPS | `queue_depth`, `api_latency_ms`, `cpu_usage_percent` |

---

## 💰 7. Cơ chế Quản lý chi phí (Cost Guard)
Nhằm duy trì hệ thống chạy liên tục 24/7 nhưng không vượt quá hạn mức ngân sách giới hạn **$200/tháng**, ứng dụng tích hợp sẵn cơ chế ngắt tải tự động:
*   **Khi chi phí đạt mức 80%:** Tiến hành rà soát lại tần suất ghi chép log và giảm bớt các kịch bản chạy test giả lập tải cao.
*   **Khi chi phí đạt mức 100% (Breaker triggered):** Hệ thống tự động kích hoạt cơ chế ngắt tải (Cost Breaker) để tạm dừng hoàn toàn việc chạy thử nghiệm tải giả lập (synthetic workload) hoặc các job phân tích tải không quan trọng. Tuy nhiên, luồng ghi nhật ký **Audit Log** và cơ chế dự phòng **Fallback** sẽ luôn luôn được giữ hoạt động để đảm bảo an toàn cho toàn hệ thống.

---

## 📝 8. Nhật ký Báo cáo Jira (Jira Task Reports)

### 📌 Task: CPOA-72 | Triển khai bảng chính sách dự phòng tĩnh (DynamoDB Service Policy Fallback)
*   **Mã Commit:** `5ea03e8adf222bc5d1eb7b51dd64a03d94be8eeb`
*   **Mô tả công việc đã làm:**
    1.  **Thiết lập bảng DynamoDB:** Định nghĩa bảng `tf4-cdo04-service-policies-sandbox` với Partition Key là `tenant_id` (S) và Sort Key là `service_name` (S).
    2.  **Khởi tạo dữ liệu mẫu (Seeding):** Nạp sẵn ngưỡng tĩnh mặc định (`static_threshold = 85.0`) cho tenant `tnt-benchmark` của 3 dịch vụ `ledger`, `payment-gw`, và `fraud-detector`.
    3.  **Cấp quyền bảo mật:** Bổ sung quyền hạn `dynamodb:GetItem` vào IAM Policy của Prediction Worker để chỉ cho phép đọc thông tin cấu hình từ bảng này.
    4.  **Tích hợp Container:** Truyền tên bảng thông qua biến môi trường `DYNAMODB_POLICY_TABLE` vào định nghĩa ECS Task Definition của Prediction Worker.
    5.  **Logic Fallback (Python app):** Lập trình hàm `get_static_threshold_fallback` gọi hàm `get_item` trên bảng DynamoDB này để lấy ngưỡng tĩnh thay thế khi kết nối tới AI Engine bị gián đoạn.

### 📌 Task: CPOA-86 | CodeDeploy canary for AI Engine
*   **Trạng thái:** POST-MVP (Tạm hoãn để tối ưu hóa tài nguyên Sandbox).
*   **Mô tả công việc đã làm:**
    1.  **Chiến lược Deployment:** Tạm hoãn triển khai CodeDeploy Canary sang giai đoạn Post-MVP để tránh phát sinh chi phí lớn trên môi trường Sandbox (theo thống nhất kiến trúc).
    2.  **Thiết lập ECS Circuit Breaker:** Cấu hình và kích hoạt cờ `enable = true` và `rollback = true` trong block `deployment_circuit_breaker` cho dịch vụ `ai-engine` tại tệp `ai_engine.tf`.
    3.  **Cơ chế bảo vệ Auto-Rollback:** Đảm bảo khi có sự cố phát sinh ở phiên bản Task Definition mới (lỗi crash-loop, port, hoặc health check `/health` fail), ECS sẽ tự động hủy đợt deploy và tự động khôi phục (rollback) ngay lập tức về phiên bản cũ hoạt động tốt gần nhất mà không làm gián đoạn dịch vụ.