# CDO-W12-016 — Schema Validation

## 1. Tổng quan & Mục tiêu
Thiết lập bộ lọc dữ liệu nghiêm ngặt sử dụng Pydantic v2 nhằm kiểm tra tính đúng đắn về kiểu dữ liệu (Schema Validation) của các datapoint telemetry đầu vào. Đảm bảo dữ liệu sai cấu trúc hoặc không hợp lệ bị từ chối ngay lập tức tại biên API, không được phép đi vào các dịch vụ lưu trữ backend (local JSONL hoặc Amazon Managed Service for Prometheus - AMP) và thực hiện tăng các bộ đếm đo lường lỗi tương ứng.

## 2. Tiêu chí nghiệm thu (Acceptance Criteria)
- [x] **`ts` phải tuân thủ RFC3339 UTC**: Chấp nhận định dạng chuẩn thời gian RFC3339 kết thúc bằng múi giờ UTC (ký tự `Z`, `z` hoặc lệch `+00:00`, `-00:00`). Từ chối các múi giờ khác.
- [x] **`value` phải là number**: Bắt buộc là số nguyên hoặc số thực có giới hạn (finite number), không chấp nhận chuỗi số ngầm định, boolean (`True`/`False`), hoặc các giá trị đặc biệt như `NaN`, `Infinity`.
- [x] **`tenant_id`/`service_id`/`metric_type` không được để trống**: Không chấp nhận chuỗi rỗng (`""`) hoặc chuỗi chỉ gồm các khoảng trắng (`"   "`).
- [x] **`labels` chỉ nhận JSON object đơn giản (flat key-value)**: Chỉ cho phép object phẳng chứa các giá trị có kiểu nguyên bản đơn giản (string, number, boolean, null). Không cho phép nested object hoặc nested array.
- [x] **Invalid payload không được ghi vào AMP/JSONL**: Dữ liệu lỗi validation bị ngắt xử lý sớm và không đi tiếp tới storage adapter/AMP delivery.
- [x] **Rejection count được log và metric hóa**: Lưu vết lý do từ chối bằng logging có cấu trúc và tăng biến đếm metric Prometheus/local tương ứng với mã lỗi (ví dụ: `invalid_timestamp`, `invalid_value`, v.v.).

## 3. Các thành phần mã nguồn liên quan trên GitHub (nhánh `main`)
Dưới đây là các liên kết trực tiếp tới các file mã nguồn liên quan trên GitHub:
- [src/telemetry_api/schemas/telemetry.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/schemas/telemetry.py): Khai báo model `TelemetryPayload` và tích hợp các `@field_validator` để kiểm tra kiểu dữ liệu nghiêm ngặt cho `ts`, `value`, `labels` và các trường chuỗi bắt buộc.
- [src/telemetry_api/validators/labels.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/validators/labels.py): Chứa hàm `validate_labels` dùng để từ chối các nested object/array trong nhãn và đảm bảo chỉ chấp nhận flat values.
- [src/telemetry_api/observability/metrics.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/observability/metrics.py): Hiện thực các hàm tăng bộ đếm metric khi có request bị reject (`record_ingest_rejected`).
- [src/telemetry_api/routes/ingest.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/routes/ingest.py): Nhận request, thực thi validate qua model và gọi hàm tăng bộ đếm metric tương ứng khi xảy ra ngoại lệ `ValidationError`.
- [src/telemetry_api/tests/telemetry_api/test_ingest_api.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/tests/telemetry_api/test_ingest_api.py): Chứa các ca kiểm thử chi tiết về timestamp RFC3339 UTC, giá trị số thực/số nguyên (bao gồm NaN, Infinity), chuỗi rỗng và cấu trúc nhãn labels phẳng.

## 4. Chi tiết hiện thực hóa

### Quy tắc kiểm tra (Validation Rules):
1. **Timestamp (`ts`) Validation**: 
   Sử dụng regex chuyên biệt `^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})$` kết hợp với thư viện `datetime.fromisoformat` để kiểm tra. Yêu cầu bắt buộc phải có thông tin timezone và phần offset phải bằng 0 (UTC).
2. **Numeric Value (`value`) Validation**:
   Sử dụng kiểm tra loại trừ: loại bỏ `bool` (vì trong Python `isinstance(True, int)` trả về `True`) và bắt buộc giá trị thuộc `int` hoặc `float`. Đồng thời dùng `math.isnan` và `math.isinf` để chặn các giá trị vô cực hoặc không xác định.
3. **Flat Labels Validation**:
   Duyệt qua các cặp key-value trong dict `labels`. Nếu phát hiện value là `dict` hoặc `list` thì ném lỗi `ValueError` ngay lập tức để chuyển thành HTTP 400 (`nested_label_object`).
4. **Metrics tracking**:
   Toàn bộ lỗi validation từ Pydantic được map sang mã lỗi cụ thể qua hàm `_determine_rejection_reason_from_exc` trong `routes/ingest.py`. Các metric local như `telemetry_ingest_rejected_total` và phân loại theo lý do được cập nhật động và expose thông qua endpoint `/debug/metrics-json`.
