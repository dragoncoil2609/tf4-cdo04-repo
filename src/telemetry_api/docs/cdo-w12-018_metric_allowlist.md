# CDO-W12-018 — Metric Allowlist

## 1. Tổng quan & Mục tiêu
Thiết lập bộ lọc và kiểm soát chặt chẽ danh sách các chỉ số đo lường (Metric Allowlist) được gửi vào hệ thống AI giám sát (AI signal window). Chỉ cho phép 7 chỉ số (signals) chính thức thuộc phạm vi hợp đồng được chấp nhận, đồng thời bắt buộc đi kèm các nhãn (labels) tương ứng để đảm bảo tính phân tích chính xác cho mô hình AI.

## 2. Tiêu chí nghiệm thu (Acceptance Criteria)
- [x] **Chấp nhận đúng 7 AI signals**:
  - `cpu_usage_percent`
  - `memory_usage_percent`
  - `active_connections`
  - `db_connection_pool_pct`
  - `queue_depth`
  - `cache_hit_rate_pct`
  - `api_latency_ms`
- [x] **Từ chối các metric ngoài allowlist**: Bất kỳ metric nào nằm ngoài danh sách đều bị chặn ngay lập tức với lý do `unsupported_metric_type`.
- [x] **Xác thực nhãn bắt buộc (Required Labels) cho từng metric**:
  - Các metric cơ bản yêu cầu nhãn: `region`.
  - `db_connection_pool_pct` yêu cầu thêm: `db_type`.
  - `queue_depth` yêu cầu thêm: `queue_name`.
  - `cache_hit_rate_pct` yêu cầu thêm: `cache_type`.
- [x] **Chặn các metric nội bộ chưa ký kết**: Các metric như `error_rate` và `oldest_message_age_seconds` bị từ chối với lý do `internal_only_metric_not_ai_signal` để tránh gửi nhầm vào AI signal window khi chưa có phụ lục hợp đồng.

## 3. Các thành phần mã nguồn liên quan trên GitHub (nhánh `main`)
Dưới đây là các liên kết trực tiếp tới các file mã nguồn liên quan trên GitHub:
- [src/telemetry_api/validators/metrics.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/validators/metrics.py): Chứa khai báo `AI_SIGNAL_ALLOWLIST`, `INTERNAL_ONLY_METRICS`, cấu trúc nhãn bắt buộc `METRIC_REQUIRED_LABELS` và hàm xác thực `validate_metric_and_labels`.
- [src/telemetry_api/schemas/telemetry.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/schemas/telemetry.py): Tích hợp hàm validator metric vào `@model_validator(mode="after")` của model `TelemetryPayload` để chạy tự động khi parse request.
- [src/telemetry_api/observability/metrics.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/observability/metrics.py): Ghi nhận metrics lỗi phân tách: `telemetry_ingest_unsupported_metric_rejected_total`, `telemetry_ingest_internal_only_metric_rejected_total`, và `telemetry_ingest_metric_label_rejected_total`.
- [src/telemetry_api/tests/telemetry_api/test_ingest_api.py](https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/src/telemetry_api/tests/telemetry_api/test_ingest_api.py): Chứa bộ test cases truyền 7 metric hợp lệ đi kèm đầy đủ nhãn, truyền metric lạ, truyền metric nội bộ bị chặn, và truyền thiếu nhãn bắt buộc/nhãn rỗng.

## 4. Chi tiết hiện thực hóa

### Quy tắc ánh xạ nhãn bắt buộc (Required Labels Mapping):
Hệ thống kiểm tra sự tồn tại của nhãn và đảm bảo giá trị của nhãn bắt buộc không được là `None` hoặc chuỗi rỗng sau khi đã cắt khoảng trắng:
```python
METRIC_REQUIRED_LABELS = {
    "cpu_usage_percent": {"region"},
    "memory_usage_percent": {"region"},
    "active_connections": {"region"},
    "api_latency_ms": {"region"},
    "db_connection_pool_pct": {"region", "db_type"},
    "queue_depth": {"region", "queue_name"},
    "cache_hit_rate_pct": {"region", "cache_type"},
}
```

### Quy trình validate metric:
1. Khi `TelemetryPayload` được khởi tạo, model validator chạy sau (after mode).
2. Lấy tên `metric_type`. Kiểm tra xem có nằm trong `INTERNAL_ONLY_METRICS` hay không. Nếu có, báo lỗi `internal_only_metric_not_ai_signal` (HTTP 400).
3. Kiểm tra xem có nằm trong `AI_SIGNAL_ALLOWLIST` hay không. Nếu không, báo lỗi `unsupported_metric_type` (HTTP 400).
4. Duyệt qua danh sách nhãn bắt buộc tương ứng. Nếu thiếu nhãn hoặc nhãn có giá trị rỗng/khoảng trắng, ném lỗi `missing_required_label` hoặc `empty_required_label` (HTTP 400).
