# CDO-W12-015 — Implement POST /v1/ingest

## 1. Tổng quan & Mục tiêu
Hiện thực hóa endpoint `POST /v1/ingest` để thu thập và xử lý các metric telemetry (chỉ số đo lường) từ các dịch vụ chạy trong hệ thống (producer services) theo mô hình Local-First. API cần đảm bảo tính hiệu năng, bảo mật và phân tách rõ ràng giữa các Tenant thông qua Header và Body Validation.

## 2. Tiêu chí nghiệm thu (Acceptance Criteria)
- [x] **API nhận POST `/v1/ingest`**: Hỗ trợ nhận dữ liệu JSON payload qua method POST.
- [x] **Trả về 201 Created** khi payload hợp lệ và lưu trữ thành công (hoặc 202 Accepted khi được ghi vào S3 failure buffer).
- [x] **Trả về 400 Bad Request** khi thiếu một trong các trường bắt buộc trong body: `tenant_id`, `service_id`, `metric_type`, `ts`, `value`.
- [x] **Trả về 400 Bad Request** khi header `X-Tenant-Id` không trùng khớp với trường `tenant_id` trong JSON body.
- [x] **Trả về 413 Payload Too Large** khi kích thước payload vượt quá giới hạn cấu hình (mặc định cấu hình qua biến môi trường `MAX_INGEST_PAYLOAD_BYTES`).
- [x] **Ghi nhận `correlation_id` trong log**: Tích hợp ID tương quan vào tất cả logs có cấu trúc (Structured JSON Logs) để phục vụ việc truy vết (tracing).

## 3. Các thành phần mã nguồn liên quan trên GitHub (nhánh `main`)
Dưới đây là các liên kết trực tiếp tới các file mã nguồn liên quan trên GitHub:
- [src/telemetry_api/main.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/main.py): Đăng ký Middleware (Payload Size, Correlation ID) và định tuyến các API Router.
- [src/telemetry_api/routes/ingest.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/routes/ingest.py): Hiện thực router chính cho endpoint `/v1/ingest`, kiểm tra header `X-Tenant-Id`, validate sự tồn tại của các trường bắt buộc và xử lý phản hồi HTTP.
- [src/telemetry_api/middleware/payload_size_limit.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/middleware/payload_size_limit.py): Middleware lọc dung lượng request body nhằm trả về mã lỗi HTTP 413 sớm trước khi ứng dụng thực hiện parse JSON.
- [src/telemetry_api/middleware/correlation_id.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/middleware/correlation_id.py): Middleware tự động sinh/bảo toàn mã correlation ID trong các header request/response `X-Correlation-Id`.
- [src/telemetry_api/core/logging.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/core/logging.py): Cấu hình định dạng log JSON có cấu trúc (Structured Logging) giúp CloudWatch dễ dàng parse trường `correlation_id`.
- [src/telemetry_api/tests/telemetry_api/test_ingest_api.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/tests/telemetry_api/test_ingest_api.py): Bộ kiểm thử tích hợp (integration tests) kiểm tra toàn bộ lỗi thiếu trường, khớp tenant, giới hạn 413 payload và tracing correlation ID.

## 4. Chi tiết hiện thực hóa

### Luồng xử lý chính (Request Flow):
1. **Payload Size Check**: `PayloadSizeLimitMiddleware` chặn request đầu tiên. Nếu kích thước body vượt quá giới hạn cho phép, trả về `413 Payload Too Large` ngay lập tức.
2. **Correlation ID Generation**: `CorrelationIdMiddleware` đọc header `X-Correlation-Id` của client. Nếu trống, middleware sẽ tự động tạo UUID mới và gán vào `request.state.correlation_id`.
3. **Tenant Header Check**: `routes/ingest.py` lấy header `X-Tenant-Id`. Nếu thiếu hoặc rỗng, trả về `400 Bad Request` với lý do `missing_tenant_header`.
4. **Mandatory Field Check**: API kiểm tra thủ công sự hiện diện của các trường `ts`, `tenant_id`, `service_id`, `metric_type`, và `value` trước khi parse sâu hơn bằng Pydantic. Nếu thiếu, raise lỗi `missing_required_field` (HTTP 400).
5. **Tenant Match Check**: So sánh `header_tenant_id` với `payload.tenant_id`. Nếu không trùng khớp, trả về `400 Bad Request` với lý do `tenant_mismatch`.
6. **Logging**: Ghi log sự kiện chấp nhận (`telemetry_ingest_accepted`) hoặc từ chối (`telemetry_ingest_rejected`) đi kèm thông tin `correlation_id` đầy đủ.
