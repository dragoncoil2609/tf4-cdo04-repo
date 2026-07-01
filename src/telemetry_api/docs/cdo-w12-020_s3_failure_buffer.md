# CDO-W12-020 — S3 Failure Buffer

## 1. Tổng quan & Mục tiêu
Thiết lập cơ chế đệm dự phòng (Failure Buffer) sử dụng Amazon S3 để tăng cường độ bền vững của dữ liệu telemetry. Khi luồng gửi đồng bộ dữ liệu tới AMP thất bại (sau số lần retry giới hạn), API sẽ ghi nhận payload lỗi vào S3 Bucket theo cấu trúc phân vùng tối ưu hóa truy vấn. Client nhận về mã phản hồi `202 Accepted` thay vì lỗi, cho phép hệ thống replay lại dữ liệu sau khi kết nối AMP được phục hồi.

## 2. Tiêu chí nghiệm thu (Acceptance Criteria)
- [x] **Lưu S3 failure buffer khi AMP fail**: Tự động chuyển hướng ghi file lên S3 khi AMP trả về lỗi hoặc timeout sau chu kỳ retry giới hạn (bounded retry).
- [x] **Trả về 202 Accepted**: Khi ghi S3 buffer thành công, API phản hồi HTTP `202 Accepted` đi kèm `event_id`, `request_id`, và `idempotency_key`.
- [x] **Trả về 5xx (503 Service Unavailable)**: Khi cả AMP và S3 buffer đều thất bại, API trả về HTTP 503 lỗi `ingest_failed`.
- [x] **S3 object có Idempotency Key**: Sinh khóa hash duy nhất dựa trên nội dung payload và đặt làm tên file để tránh ghi đè/trùng lặp dữ liệu.
- [x] **Cảnh báo Alarm khi object age > 5 phút**: Thiết lập CloudWatch Alarm cảnh báo khi có tệp tin nằm trong buffer quá 5 phút chưa được replay thành công.

## 3. Các thành phần mã nguồn liên quan trên GitHub (nhánh `main`)
Dưới đây là các liên kết trực tiếp tới các file mã nguồn liên quan trên GitHub:
- [src/telemetry_api/services/ingest_service.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/services/ingest_service.py): Điều phối luồng gọi gửi AMP, thực hiện retry logic và chuyển tiếp lưu S3 khi AMP báo lỗi, raise lỗi `BothAMPAndS3FailedError` khi cả hai hướng đều fail.
- [src/telemetry_api/adapters/s3_failure_buffer_adapter.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/adapters/s3_failure_buffer_adapter.py): Thực hiện write file vào AWS S3 (hoặc giả lập cục bộ), định hình cấu trúc phân vùng S3 key và gán Metadata (idempotency key, event ID).
- [src/telemetry_api/core/idempotency.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/core/idempotency.py): Định nghĩa hàm `generate_idempotency_key` băm dữ liệu SHA-256 các trường chính của telemetry.
- [src/telemetry_api/core/retry.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/core/retry.py): Trình tiện ích thực thi hàm bất kỳ kèm cơ chế Exponential Backoff có cấu hình số lần retry.
- [src/telemetry_api/services/replay_service.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/services/replay_service.py): Quét các tệp JSON lỗi từ S3, thực hiện replay gửi lại AMP và xóa tệp tin S3 sau khi gửi thành công.
- [src/telemetry_api/tests/telemetry_api/test_s3_failure_buffer.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/tests/telemetry_api/test_s3_failure_buffer.py): Bộ kiểm thử tích hợp giả lập các tình huống: AMP thành công, AMP lỗi cần retry thành công, AMP lỗi hoàn toàn S3 ghi thành công (202), AMP lỗi + S3 lỗi (503), và kiểm tra dịch vụ replay.

## 4. Chi tiết hiện thực hóa

### Cấu trúc phân vùng lưu trữ S3:
Để tối ưu hóa việc phân tách dữ liệu và hỗ trợ công cụ truy vấn AWS Athena/AWS Glue Crawler, tệp lỗi được ghi theo cấu trúc phân mục động:
```text
s3://<S3_FAILURE_BUFFER_BUCKET>/telemetry-failures/tenant_id=<tenant_id>/service_id=<service_id>/metric_type=<metric_type>/date=<YYYY-MM-DD>/idempotency_key=<hash>.json
```
- **`date`**: Định dạng `YYYY-MM-DD` được trích xuất động từ trường thời gian `ts` của telemetry payload.
- **`idempotency_key`**: Khóa SHA-256 mã hóa của:
  `sha256(tenant_id + service_id + metric_type + ts + value + sorted_labels)`

### Cấu hình CloudWatch Alarm:
Để theo dõi và cảnh báo các tệp tin lưu trong S3 quá lâu (ví dụ do AMP mất kết nối diện rộng), CloudWatch Alarm được thiết lập dựa trên custom metric `telemetry_failure_buffer_oldest_object_age_seconds` hoặc thông qua AWS Config/EventBridge Rule theo dõi sự kiện S3 Object Creation Age. Nếu chỉ số lớn hơn `300` giây (5 phút), hệ thống sẽ gửi cảnh báo SNS tới nhóm vận hành.
