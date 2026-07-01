# CDO-W12-017 — PII and Label Denylist

## 1. Tổng quan & Mục tiêu
Đảm bảo an toàn thông tin PII (Personally Identifiable Information - Thông tin định danh cá nhân) và bảo vệ hiệu năng hệ thống giám sát bằng cách ngăn chặn việc đưa các nhãn nhạy cảm hoặc nhãn có độ phân biệt quá cao (High Cardinality) vào telemetry backend. Hệ thống sẽ tự động quét, từ chối request vi phạm và ghi nhận logs mà không làm rò rỉ dữ liệu nhạy cảm.

## 2. Tiêu chí nghiệm thu (Acceptance Criteria)
- [x] **Từ chối nhãn thuộc PII Denylist**: Từ chối toàn bộ request chứa các trường nhãn nhạy cảm hoặc tài chính như `email`, `phone`, `name`, `transaction_id`, `account_id`, `card_pan`, `user_id`, `request_id`, `trace_id`, `prediction_id`.
- [x] **Từ chối nhãn High Cardinality**: Chặn các khóa nhãn gây bùng nổ cardinality trong database như `session_id`, `raw_path`, `path_with_id`.
- [x] **Từ chối raw endpoint path chứa IDs**: Phát hiện và chặn các giá trị nhãn có dạng đường dẫn API chứa mã định danh động (ví dụ: `/users/12345/orders`).
- [x] **Log không in thông tin nhạy cảm (No raw sensitive values)**: Khi từ chối do PII, log hệ thống chỉ in tên key vi phạm (denied key) hoặc lý do từ chối chung, tuyệt đối không in ra giá trị nhạy cảm thực tế do client gửi lên.
- [x] **Tăng CloudWatch/Local metric khi từ chối**: Tích hợp các bộ đếm chuyên biệt như `telemetry_ingest_pii_rejected_total` và `telemetry_ingest_cardinality_rejected_total` phục vụ cho việc giám sát và cảnh báo lỗi bảo mật trên CloudWatch.

## 3. Các thành phần mã nguồn liên quan trên GitHub (nhánh `main`)
Dưới đây là các liên kết trực tiếp tới các file mã nguồn liên quan trên GitHub:
- [src/telemetry_api/validators/labels.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/validators/labels.py): Khai báo danh sách cấm `PII_DENYLIST_KEYS`, `HIGH_CARDINALITY_LABEL_KEYS`, và hàm `looks_like_raw_path_with_ids` để nhận diện dynamic IDs trong path segments.
- [src/telemetry_api/observability/metrics.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/observability/metrics.py): Hiện thực các hàm tăng bộ đếm metric riêng cho PII (`record_pii_rejection`) và Cardinality (`record_cardinality_rejection`).
- [src/telemetry_api/routes/ingest.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/routes/ingest.py): Nhận diện lỗi ném ra từ validator nhãn, lấy tên key bị cấm (stripped/sanitized) và thực hiện log an toàn mà không in giá trị value nhạy cảm.
- [src/telemetry_api/tests/telemetry_api/test_ingest_api.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/tests/telemetry_api/test_ingest_api.py): Bao gồm các test case kiểm tra 10 key PII cấm, lỗi high cardinality, định danh path chứa ID động, kiểm tra logs an toàn và tăng bộ đếm lỗi bảo mật.

## 4. Chi tiết hiện thực hóa

### Thuật toán phát hiện và Xử lý:
1. **PII Key Check**:
   Khi parse nhãn, toàn bộ key sẽ được chuẩn hóa thành chữ thường (`.lower()`) và so sánh với tập hợp cấm `PII_DENYLIST_KEYS`. Bất kỳ sự trùng khớp nào đều ném lỗi `ValueError` kèm tên key vi phạm.
2. **Sensitive Value Marker Check**:
   Không chỉ chặn ở key, nếu value của nhãn là chuỗi ký tự và chứa các marker nhạy cảm (như chứa chuỗi "password", "secret", "token", "credential", hoặc định dạng số thẻ tín dụng `card_pan`), request cũng sẽ bị từ chối sớm.
3. **Raw Endpoint Path with IDs detection**:
   Hàm `looks_like_raw_path_with_ids` chia nhỏ value dạng path (chứa dấu `/`) thành các segment. Nếu có bất kỳ segment nào trông giống mã định danh động (chỉ chứa số nguyên, dạng UUID, có prefix chứa số như `acc_123`, hoặc chuỗi hỗn hợp chữ số dài `>= 4`), phân đoạn đó bị coi là ID động và nhãn bị chặn để tránh bùng nổ cardinality.
4. **Bảo vệ Logs (Data Leak Protection)**:
   Trong exception handler của `main.py`, khi ném lỗi `TelemetryApiError`, hệ thống chỉ nhận tham số `denied_key` (ví dụ: `"email"` hoặc `"session_id"`) để ghi nhận vào log JSON:
   `"reason": "pii_denylist_label", "denied_key": "email"`. Giá trị nhạy cảm (như `"user@domain.com"`) hoàn toàn bị loại bỏ khỏi luồng ghi log và response payload.
