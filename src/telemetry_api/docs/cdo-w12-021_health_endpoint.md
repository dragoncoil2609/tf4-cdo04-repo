# CDO-W12-021 — /health Endpoint

## 1. Tổng quan & Mục tiêu
Cung cấp endpoint `/health` gọn nhẹ, an toàn để phục vụ công tác kiểm tra trạng thái hoạt động (health checking) từ AWS Application Load Balancer (ALB), ECS Container Agent, và các hệ thống giám sát. Endpoint cần trả về thông tin tối giản về phiên bản ứng dụng và thông tin build mà không tiết lộ bất kỳ thông tin nhạy cảm hay bí mật cấu hình nào.

## 2. Tiêu chí nghiệm thu (Acceptance Criteria)
- [x] **GET `/health` trả về HTTP 200 OK**: Trả về trạng thái hoạt động thành công của ứng dụng.
- [x] **ECS Health Check Pass**: Cấu hình endpoint tương thích hoàn toàn với tần suất ping và định dạng yêu cầu của ECS Task Health Check.
- [x] **Không rò rỉ dữ liệu nhạy cảm**: Tuyệt đối không in hoặc trả về các khóa bí mật (AWS keys, database password, API tokens) trong response body.
- [x] **Có thông tin build và version tối thiểu**: Trả về tên ứng dụng, phiên bản (app_version), build_id, commit_sha, env, và app_mode.

## 3. Các thành phần mã nguồn liên quan trên GitHub (nhánh `main`)
Dưới đây là các liên kết trực tiếp tới các file mã nguồn liên quan trên GitHub:
- [src/telemetry_api/routes/health.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/routes/health.py): File chứa logic định nghĩa route `/health` và trả về JSON metadata của ứng dụng.
- [src/telemetry_api/main.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/main.py): Đăng ký `health_router` vào ứng dụng FastAPI.
- [src/telemetry_api/core/config.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/core/config.py): Định nghĩa các trường cấu hình thông tin build (`build_id`, `git_commit_sha`, `app_version`).
- [src/telemetry_api/tests/telemetry_api/test_ingest_api.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/tests/telemetry_api/test_ingest_api.py): Chứa test cases kiểm tra GET `/health` trả 200, kiểm duyệt danh sách các từ khóa nhạy cảm không được phép xuất hiện trong text response (như password, key, secret, token, aws_secret_access_key) và đảm bảo health check không làm thay đổi trạng thái của storage.

## 4. Chi tiết hiện thực hóa

### Cấu trúc dữ liệu trả về (JSON Response Schema):
```json
{
  "status": "ok",
  "service": "telemetry-api",
  "version": "0.1.0",
  "build_id": "build-12345",
  "commit_sha": "a1b2c3d4e5f6...",
  "environment": "prod",
  "app_mode": "aws",
  "storage_backend": "prometheus_amp"
}
```

### Bảo vệ rò rỉ thông tin (Security Controls):
1. **No-storage mutation**: Endpoint `/health` là một hàm đọc thuần túy, tuyệt đối không kích hoạt ghi logs/dữ liệu vào file JSONL hoặc DB để tránh tràn dung lượng đĩa do các luồng ping liên tục từ ALB/ECS.
2. **Explicit Fields Mapping**: Chỉ các trường đã định nghĩa rõ ràng trong `routes/health.py` mới được đưa vào JSON response. Tuyệt đối không serialize toàn bộ dict của `settings` (vì `settings` chứa thông tin nhạy cảm như database credentials hay AWS keys).
