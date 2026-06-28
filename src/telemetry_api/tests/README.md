# Hướng Dẫn Chạy Kiểm Thử (Unit Tests) & Metrics - Telemetry API

Tài liệu này hướng dẫn cách chạy các ca kiểm thử tự động (unit tests) và kiểm thử thủ công cho ứng dụng Telemetry API bao gồm các tính năng nâng cấp Schema Validation (CDO-W12-016) và PII / Label Denylist (CDO-W12-017).

---

## 1. Chuẩn bị môi trường

Tùy thuộc vào thư mục hiện tại của bạn trong Terminal:

* **Nếu bạn đang ở thư mục gốc của dự án (`tf4-cdo04-repo`):**
  ```bash
  pip install -r src/telemetry_api/requirements.txt
  ```

* **Nếu bạn đang ở trong thư mục `src` (`tf4-cdo04-repo/src`):**
  ```bash
  pip install -r telemetry_api/requirements.txt
  ```

*(Lưu ý: Môi trường của bạn cần cài đặt `pytest`, `pytest-cov`, `fastapi`, `pydantic` và `httpx` để TestClient hoạt động).*

---

## 2. Cách chạy kiểm thử tự động (Unit Tests)

Vì mã nguồn ứng dụng nằm trong thư mục `src`, bạn cần thiết lập biến môi trường `PYTHONPATH` để Python tìm thấy module `telemetry_api` khi chạy `pytest`.

### A. Nếu bạn đang ở thư mục gốc của dự án (`tf4-cdo04-repo`):
* **Chạy tests thông thường (chỉ hiện dấu chấm):**
  ```powershell
  $env:PYTHONPATH="src"
  pytest src/telemetry_api
  ```
* **Chạy chi tiết từng test case (Verbose - hiện tên từng test):**
  ```powershell
  $env:PYTHONPATH="src"
  pytest -v src/telemetry_api
  ```
* **Chạy chi tiết + In cả log/print ra console (giống chạy thủ công):**
  ```powershell
  $env:PYTHONPATH="src"
  pytest -sv src/telemetry_api
  ```

### B. Nếu bạn đang ở trong thư mục `src` (`tf4-cdo04-repo/src`):
* **Chạy tests thông thường (chỉ hiện dấu chấm):**
  ```powershell
  $env:PYTHONPATH="."
  pytest telemetry_api
  ```

---

## 3. Các kịch bản kiểm thử đã được tự động hóa (73 Test Cases)

Bộ mã nguồn kiểm thử nằm tại `src/telemetry_api/tests/telemetry_api/test_ingest_api.py` bao gồm 73 kịch bản quan trọng sau:

1. **`test_valid_payload_returns_201_and_writes_jsonl`**: Kiểm tra gói tin hợp lệ được chấp nhận và ghi đúng định dạng vào file log cục bộ (`telemetry.jsonl`).
2. **`test_metrics_endpoint_initial_state` / `test_accepted_request_increments_metric`**: Đảm bảo bộ đếm `/metrics` phản ánh đúng các request thành công và thất bại.
3. **`test_timestamp_validation`**: Chỉ cho phép định dạng RFC3339 UTC kết thúc bằng `Z` hoặc offset không đổi lệch 0 (như `+00:00`). Từ chối naive datetime hoặc múi giờ lệch (ví dụ `+07:00`).
4. **`test_value_validation` / `test_nan_infinity_value_validation`**: Đảm bảo giá trị metric bắt buộc phải là số thực hoặc số nguyên (từ chối string, boolean, null, NaN, Infinity).
5. **`test_non_empty_string_fields`**: Các trường text định danh phải là kiểu chuỗi và không được để trống hoặc chỉ có khoảng trắng.
6. **`test_labels_validation`**: Kiểm tra các ràng buộc kiểu nhãn labels phẳng, cấm lồng nhau (nested dicts/arrays).
7. **`test_pii_denylist_keys`**: Đảm bảo toàn bộ 10 keys cấm PII (`email`, `phone`, `name`, `transaction_id`, `account_id`, `card_pan`, `user_id`, `request_id`, `trace_id`, `prediction_id`) đều bị từ chối với HTTP 400.
8. **`test_high_cardinality_keys`**: Đảm bảo các key có cardinality cao (`session_id`, `raw_path`) bị chặn.
9. **`test_raw_path_with_ids_values`**: Kiểm thử phát hiện path chứa ID động (UUID, ID số, prefix_ID như `acc_123`, hoặc chuỗi hash hỗn hợp).
10. **`test_pii_and_cardinality_rejection_storage_protection`**: Chứng minh các request vi phạm PII và cardinality tuyệt đối không được ghi vào file lưu trữ local JSONL.
11. **`test_pii_and_cardinality_metrics_increments`**: Xác nhận các bộ đếm `telemetry_ingest_pii_rejected_total` và `telemetry_ingest_cardinality_rejected_total` tăng chính xác theo từng loại lỗi.
12. **`test_pii_denylist_logging_and_response_no_leak`**: Đảm bảo thông tin email thô nhạy cảm không bị lộ ra cả JSON response lẫn logs hệ thống (chỉ ghi key bị cấm).

---

## 4. Hướng dẫn kiểm thử thủ công (Manual Testing)

### Bước 1: Khởi chạy Uvicorn Server cục bộ
```powershell
$env:PYTHONPATH="src"
python -m uvicorn telemetry_api.main:app --reload --port 8000
```
*Server sẽ lắng nghe tại: `http://127.0.0.1:8000`*

### Bước 2: Kiểm tra trạng thái Metrics ban đầu
Gửi request GET đến `/metrics` để xem bộ đếm ban đầu:
```powershell
Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8000/metrics"
```
**Phản hồi kỳ vọng:**
```json
{
  "telemetry_ingest_accepted_total": 0,
  "telemetry_ingest_rejected_total": 0,
  "telemetry_ingest_pii_rejected_total": 0,
  "telemetry_ingest_cardinality_rejected_total": 0,
  "telemetry_ingest_rejected_by_reason": {}
}
```

### Bước 3: Gửi Request kiểm thử

* **Gửi Request hợp lệ (PowerShell):**
  ```powershell
  Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
    -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
    -Body '{
      "ts": "2026-06-25T10:30:00Z",
      "tenant_id": "demo-tenant-001",
      "service_id": "payment-gateway",
      "metric_type": "api_latency_ms",
      "value": 450.5,
      "labels": { "region": "us-east-1", "env": "local" }
    }'
  ```

* **Gửi Request lỗi (Chứa label PII - `email` - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00Z",
          "tenant_id": "demo-tenant-001",
          "service_id": "payment-gateway",
          "metric_type": "api_latency_ms",
          "value": 450.5,
          "labels": {
            "email": "user@example.com"
          }
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "label key is denied by PII policy: email")*

* **Gửi Request lỗi (Chứa label cardinality cao - `request_id` - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00Z",
          "tenant_id": "demo-tenant-001",
          "service_id": "payment-gateway",
          "metric_type": "api_latency_ms",
          "value": 450.5,
          "labels": {
            "request_id": "req-123"
          }
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "label key is denied by high-cardinality policy: request_id")*

* **Gửi Request lỗi (Chứa raw path có ID động - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00Z",
          "tenant_id": "demo-tenant-001",
          "service_id": "payment-gateway",
          "metric_type": "api_latency_ms",
          "value": 450.5,
          "labels": {
            "path": "/users/12345/orders/98765"
          }
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "label value is denied because it looks like raw endpoint path with IDs")*

### Bước 4: Kiểm tra lại Metrics sau khi gửi các request
```powershell
Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8000/metrics"
```
**Phản hồi kỳ vọng:**
```json
{
  "telemetry_ingest_accepted_total": 1,
  "telemetry_ingest_rejected_total": 3,
  "telemetry_ingest_pii_rejected_total": 1,
  "telemetry_ingest_cardinality_rejected_total": 2,
  "telemetry_ingest_rejected_by_reason": {
    "pii_denylist_label": 1,
    "high_cardinality_label": 1,
    "raw_endpoint_path_with_ids": 1
  }
}
```
