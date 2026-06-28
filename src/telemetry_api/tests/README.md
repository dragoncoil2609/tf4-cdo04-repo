# Hướng Dẫn Chạy Kiểm Thử (Unit Tests) & Metrics - Telemetry API

Tài liệu này hướng dẫn cách chạy các ca kiểm thử tự động (unit tests) và kiểm thử thủ công cho ứng dụng Telemetry API bao gồm các tính năng nâng cấp Schema Validation (CDO-W12-016).

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
* **Chạy kèm báo cáo Code Coverage:**
  ```powershell
  $env:PYTHONPATH="src"
  pytest --cov=src/telemetry_api src/telemetry_api
  ```

### B. Nếu bạn đang ở trong thư mục `src` (`tf4-cdo04-repo/src`):
* **Chạy tests thông thường (chỉ hiện dấu chấm):**
  ```powershell
  $env:PYTHONPATH="."
  pytest telemetry_api
  ```
* **Chạy chi tiết từng test case (Verbose - hiện tên từng test):**
  ```powershell
  $env:PYTHONPATH="."
  pytest -v telemetry_api
  ```
* **Chạy chi tiết + In cả log/print ra console (giống chạy thủ công):**
  ```powershell
  $env:PYTHONPATH="."
  pytest -sv telemetry_api
  ```

---

## 3. Các kịch bản kiểm thử đã được tự động hóa (52 Test Cases)

Bộ mã nguồn kiểm thử nằm tại `src/telemetry_api/tests/telemetry_api/test_ingest_api.py` bao gồm các kịch bản quan trọng sau:

1. **`test_valid_payload_returns_201_and_writes_jsonl`**: Kiểm tra gói tin hợp lệ được chấp nhận và ghi đúng định dạng vào file log cục bộ (`telemetry.jsonl`).
2. **`test_metrics_endpoint_initial_state` / `test_accepted_request_increments_metric`**: Đảm bảo bộ đếm `/metrics` phản ánh đúng các request thành công và thất bại.
3. **`test_timestamp_validation`**: Kiểm thử toàn diện kiểm tra tính hợp lệ của timestamp. Chỉ cho phép định dạng RFC3339 UTC kết thúc bằng `Z` hoặc offset không đổi lệch 0 (như `+00:00`). Từ chối naive datetime hoặc múi giờ lệch (ví dụ `+07:00`).
4. **`test_value_validation` / `test_nan_infinity_value_validation`**: Đảm bảo giá trị metric bắt buộc phải là số thực hoặc số nguyên (từ chối string, boolean, null, NaN, Infinity).
5. **`test_non_empty_string_fields`**: Các trường text định danh phải là kiểu chuỗi và không được để trống hoặc chỉ có khoảng trắng.
6. **`test_labels_validation`**: Kiểm tra các ràng buộc kiểu nhãn labels phẳng, cấm lồng nhau (nested dicts/arrays), lọc bỏ nhãn có tính bảo mật cao (PII) hoặc cardinality lớn.
7. **`test_tenant_header_body_mismatch_returns_400` / `test_missing_tenant_header_returns_400`**: Kiểm tra logic cô lập Tenant.
8. **`test_payload_too_large_rejection_metrics`**: Kiểm tra middleware chặn các request có dung lượng vượt ngưỡng giới hạn cho phép (413) và ghi nhận lý do `payload_too_large`.
9. **`test_invalid_json_returns_400`**: Từ chối gói tin JSON bị lỗi cú pháp trước khi xử lý.

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
      "labels": { "region": "us-east-1" }
    }'
  ```

* **Gửi Request lỗi (Timestamp sai định dạng múi giờ - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00+07:00",
          "tenant_id": "demo-tenant-001",
          "service_id": "payment-gateway",
          "metric_type": "api_latency_ms",
          "value": 450.5
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "ts must be RFC3339 UTC")*

* **Gửi Request lỗi (Value là boolean thay vì số - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00Z",
          "tenant_id": "demo-tenant-001",
          "service_id": "payment-gateway",
          "metric_type": "api_latency_ms",
          "value": true
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "value must be a number")*

* **Gửi Request lỗi (Labels chứa đối tượng lồng nhau - PowerShell):**
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
            "metadata": { "region": "us-east-1" }
          }
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "labels cannot contain nested objects or arrays for key 'metadata'")*

### Bước 4: Kiểm tra lại Metrics sau khi gửi các request
```powershell
Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8000/metrics"
```
**Phản hồi kỳ vọng:**
```json
{
  "telemetry_ingest_accepted_total": 1,
  "telemetry_ingest_rejected_total": 3,
  "telemetry_ingest_rejected_by_reason": {
    "invalid_timestamp": 1,
    "invalid_value": 1,
    "nested_label_object": 1
  }
}
```
