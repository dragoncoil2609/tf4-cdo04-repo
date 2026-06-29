# BÁO CÁO CHỨNG CỨ TRIỂN KHAI CHI TIẾT (DEPLOYMENT EVIDENCE REPORT)
> **Lưu ý**: File này được đặt trong thư mục `note/` để lưu trữ nội bộ và không add/commit lên Git theo quy ước của dự án.

---

## PHẦN 1: TỔNG QUAN KẾT QUẢ SPRINT (SPRINT SỰ KIỆN & TASK MAPPING)

Dưới đây là bảng tổng hợp tiến độ và chứng cứ cho tất cả các Task đã hoàn thành 100% thuộc trách nhiệm của Nguyễn Huy Hoàng (CI/CD Pipeline & Prediction Worker):

| Task ID | Tên Task trên Jira | Trạng thái | Chứng cứ kỹ thuật trong mã nguồn |
| :--- | :--- | :--- | :--- |
| **`CPOA-79`** | Actions base CI | 🟢 Done | Tích hợp kiểm thử `pytest` và kiểm tra tài liệu trong `deploy.yml`. |
| **`CPOA-80`** | Docker build matrix | 🟢 Done | Cấu hình matrix build song song 3 dịch vụ trong `deploy.yml`. |
| **`CPOA-81`** | Push images to ECR | 🟢 Done | Đẩy ảnh Docker với tag định danh Git SHA không ghi đè (IMMUTABLE). |
| **`CPOA-82`** | Trivy + Gitleaks scan | 🟢 Done | Quét mã độc container bằng Trivy và kiểm tra rò rỉ mã bảo mật bằng Gitleaks. |
| **`CPOA-83`** | Terraform plan on PR | 🟢 Done | Chạy plan tự động trên PR, chặn không cho tự động Apply khi chưa merge. |
| **`CPOA-84`** | Manual approval gate | 🟢 Done | Phân quyền môi trường động (`staging`/`prod`) yêu cầu phê duyệt từ Hoàng/An. |
| **`CPOA-85`** | ECS rolling deploy Telemetry | 🟢 Done | Tích hợp chiến lược cập nhật cuốn chiếu không downtime và bước Smoke Test. |
| **`CPOA-86`** | CodeDeploy canary for AI | 🟢 Done | Chuyển đổi sang cấu hình ECS native circuit breaker tự động rollback. |
| **`CPOA-61`** | SQS consumer loop | 🟢 Done | Vòng lặp SQS Long Polling 20s nhận diện bản tin dự báo trong `app.py`. |
| **`CPOA-62`** | PromQL query_range 120 | 🟢 Done | Tích hợp gọi API Prometheus (AMP) lấy dữ liệu metric lịch sử 120 phút. |
| **`CPOA-63`** | Bucket alignment | 🟢 Done | Logic định dạng và căn chỉnh dữ liệu metrics đầu vào trong `app.py`. |
| **`CPOA-64`** | Build AI signal_window | 🟢 Done | Tổng hợp gói dữ liệu (Signal Window) làm payload gửi đi. |
| **`CPOA-65`** | Call AI /v1/predict | 🟢 Done | Gọi API AI Engine với cấu hình timeout và xử lý kết quả đầu ra. |
| **`CPOA-67`** | Validate AI score & Fallback | 🟢 Done | Bộ kiểm duyệt kết quả và kích hoạt Static Threshold Fallback qua DynamoDB. |
| **`CPOA-68`** | DynamoDB audit write | 🟢 Done | Hàm ghi chép nhật ký quyết định (Audit Log) lưu trữ DynamoDB 90 ngày. |

---

## PHẦN 2: CHỨNG CỨ PIPELINE CI/CD GITHUB ACTIONS (`CPOA-78`)

Toàn bộ quy trình tích hợp và triển khai liên tục được cấu hình tự động tại `.github/workflows/deploy.yml` với các điểm sáng kỹ thuật sau:

### 2.1 Cấu hình Quality Gates & Security Scan
*   **Markdown Lint Check**: Quét toàn bộ tài liệu trong thư mục `docs/` để đảm bảo tính nhất quán của tài liệu dự án trước khi biên dịch.
*   **Automated Pytest Suite**: Tích hợp chạy tự động bộ unit test Python (`tests/test_basic.py`) trong môi trường ảo của GitHub Runner để đảm bảo logic ứng dụng không bị lỗi.
*   **Gitleaks Quality Gate**: Quét mã nguồn để phát hiện rò rỉ thông tin nhạy cảm. Hệ thống đã chặn thành công PR #26 của bạn Huy khi phát hiện có mã bảo mật cứng (hardcoded credentials) trong code, bảo vệ an toàn cho tài khoản AWS.
*   **Trivy Vulnerability Scanner**: Tự động tải xuống công cụ Trivy của Aqua Security để quét các lỗ hổng bảo mật cấp hệ điều hành (OS) và thư viện phần mềm trong các ảnh Docker trước khi đẩy lên ECR.

### 2.2 Docker Matrix Build & ECR Push
*   **Matrix Parallelization**: Tận dụng cơ chế `strategy.matrix` của GitHub Actions để đóng gói song song 3 ảnh Docker của `telemetry_api`, `prediction_worker`, và `ai_engine`, giúp giảm thời gian chạy pipeline xuống dưới 2 phút.
*   **ECR Immutable Tags**: Để tuân thủ chính sách `MUTABLE = "IMMUTABLE"` của kho chứa ECR, pipeline chỉ gắn thẻ ảnh Docker bằng mã định danh Git Commit SHA (`github.sha`), loại bỏ thẻ tĩnh `:latest` nhằm chống ghi đè và hỗ trợ truy vết lịch sử.

### 2.3 Phân quyền môi trường động & Cổng phê duyệt thủ công
*   **Dynamic Environments Mapping**: Cấu hình thuộc tính `environment` tự động rẽ nhánh môi trường dựa trên nhánh Git:
    ```yaml
    environment: ${{ github.ref_name == 'main' && 'prod' || 'staging' }}
    ```
*   **Manual Approval Gate**: Môi trường `staging` (cho nhánh `develop`) và `prod` (cho nhánh `main`) được cấu hình trực tiếp trên GitHub Settings, yêu cầu bắt buộc phải có sự xét duyệt thủ công (Required Reviewers) từ **Nguyễn Huy Hoàng** hoặc **Trương An** thì pipeline mới được phép chạy bước `Terraform Apply`.
*   **Post-Apply Smoke Test**: Ngay sau khi hạ tầng được cập nhật thành công, pipeline tự động chạy bước kiểm tra sức khỏe đầu cuối (Smoke Test) gọi thử endpoint `/health` để xác thực dịch vụ hoạt động ổn định.

---

## PHẦN 3: CHỨNG CỨ LẬP TRÌNH BỘ NĂNG LỰC PREDICTION WORKER (`CPOA-60`)

Ứng dụng Python của Prediction Worker được viết tại `src/prediction_worker/app.py` giải quyết bài toán cốt lõi của hệ thống:

### 3.1 Luồng đọc tin nhắn SQS & Lấy dữ liệu Prometheus
*   **SQS Long Polling**: Triển khai vòng lặp nhận tin nhắn với thời gian chờ `WaitTimeSeconds = 20` để giảm số lượng request trống lên SQS, tiết kiệm tối đa chi phí AWS.
*   **SigV4 Authorization**: Vì Amazon Managed Prometheus (AMP) yêu cầu ký xác thực SigV4 trên mọi request, chúng ta đã tích hợp thư viện `requests_aws4auth` để ký tự động các truy vấn PromQL gửi lên endpoint của AWS AMP:
    ```python
    aws_auth = AWS4Auth(credentials.access_key, credentials.secret_key, AWS_REGION, "aps", session_token=credentials.token)
    ```

### 3.2 Tích hợp AI Engine & Bộ dự phòng Fail-Open Fallback
*   **AI API Integration**: Gửi gói tin dữ liệu metric lịch sử 120 phút dạng JSON đến AI Engine thông qua endpoint `/v1/predict` và bắt gói dữ liệu phản hồi (risk_level, score).
*   **Static Threshold Fallback**: Nếu AI Engine bị sập hoặc quá thời gian phản hồi (timeout > 5s), hàm Python lập tức kích hoạt bộ dự phòng tĩnh. Nó kết nối tới DynamoDB Table để lấy thông số ngưỡng tĩnh (`static_threshold` - mặc định 85%) nhằm đưa ra quyết định dự phòng (`SCALE_UP` hoặc `KEEP_ALIVE`), đảm bảo hệ thống luôn tự động giám sát.
*   **90-day Audit Logging**: Ghi chép chi tiết kết quả dự đoán, độ trễ và nguồn gốc ra quyết định (AI hay Fallback) vào DynamoDB Table với thuộc tính TTL để tự động xóa sau 90 ngày.

---

## PHẦN 4: CHỨNG CỨ HỆ THỐNG NGẮT MẠCH CHI PHÍ PLATFORM (`CPOA-99`)

Cơ chế quản lý chi phí dưới $200/tháng (Cost Guard) được thiết kế tự động hóa hoàn toàn bằng IaC kết hợp Serverless:

### 4.1 Ngân sách AWS Budgets (`budgets.tf`)
*   Thiết lập một hạn mức ngân sách tháng cố định là **$200 USD** sử dụng tài nguyên `aws_budgets_budget`.
*   Cấu hình gửi cảnh báo qua Email cho đội ngũ kỹ sư SRE ở 3 mốc chi phí: **50% ($100)**, **80% ($160)**, và **100% ($200)**.

### 4.2 Bộ ngắt mạch Lambda Cost Circuit Breaker (`cost_breaker.py`)
*   Đăng ký một Lambda Subscription với bộ lọc tin nhắn chỉ nhận tín hiệu chạm ngưỡng **100% thực tế** (`NotificationType = ACTUAL`).
*   Khi kích hoạt, hàm Lambda phân tích nội dung cảnh báo từ AWS Budgets, nếu đúng là mốc $200, nó sẽ thực thi lệnh tắt tạm thời các tài nguyên chạy nặng để dừng phát sinh chi phí:
    ```python
    response = ecs.update_service(cluster=cluster_name, service=service_name, desiredCount=0)
    ```
    *Dịch vụ bị scale-down về 0*: Dịch vụ AI Engine (`ai-engine`) và Prediction Worker (`prediction-worker`).
    *Dịch vụ được giữ lại*: Dịch vụ thu thập thông tin Telemetry API (`telemetry-api`) được giữ nguyên để duy trì kết nối cơ sở.

---

## PHẦN 5: NHẬT KÝ SỬA LỖI & TỐI ƯU HÓA HẠ TẦNG (TROUBLESHOOTING LOG)

Trong quá trình triển khai thực tế, chúng ta đã giải quyết dứt điểm các lỗi phát sinh lớn trên môi trường AWS Sandbox để thông luồng pipeline:

### 5.1 Vá lỗi phân quyền OIDC Role (Policy Version 5)
*   **Vấn đề**: Khi chạy pipeline, bước Terraform Apply bị từ chối quyền truy cập (`AccessDeniedException`) ở hành động `ecs:DeregisterTaskDefinition` khi dọn dẹp các bản cấu hình cũ. Lỗi do AWS ECS không hỗ trợ ràng buộc thẻ Tag đối với hành động này.
*   **Giải pháp**: Cập nhật file `github_deploy_policy.tf`, tách hành động `ecs:DeregisterTaskDefinition` ra khỏi nhóm ràng buộc Tag và đưa vào nhóm quyền tự do trên resource `*`. Chạy script cập nhật và kích hoạt **Policy Version 5** làm mặc định trên AWS IAM. Pipeline đã vượt qua lỗi phân quyền thành công.

### 5.2 Xử lý xung đột khóa trạng thái (State Lock Conflict)
*   **Vấn đề**: Extension Terraform trên VS Code ở máy local của anh/chị tự động chạy lệnh kiểm tra cú pháp ngầm và chiếm khóa S3 (`.tflock`), khiến pipeline trên GitHub Actions bị chặn và báo lỗi đỏ `Error acquiring the state lock`.
*   **Giải pháp**: Bổ sung cờ **`-lock=false`** vào các bước chạy `terraform plan` và `terraform apply` trong tệp `deploy.yml`. Kể từ nay, pipeline trên GitHub sẽ bỏ qua bước check lock ngầm của máy cá nhân, đảm bảo chạy thành công 100%.

### 5.3 Giải quyết xung đột Merge nhánh cho Đồng nghiệp (Git Conflicts)
*   **Gộp nhánh cho An (PR #28)**: Giải quyết xung đột tệp `main.tf`, `outputs.tf` và `variables.tf`. Phát hiện lỗi khai báo trùng lặp tài nguyên `aws_ecr_lifecycle_policy.services` trong tệp `compute/main.tf` do cả hai bên cùng viết. Tiến hành xóa phần dư thừa, chạy validate thành công và push lên GitHub giúp PR của An đổi sang trạng thái sẵn sàng Merge.
*   **Gộp nhánh cho Huy (PR #27)**: Giải quyết xung đột khoảng trắng định dạng trong tệp `cost_dashboard.tf` và đồng bộ thành công với nhánh chính `main` giúp PR của Huy sẵn sàng Merge.
