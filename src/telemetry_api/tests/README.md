# Hướng Dẫn Chạy Kiểm Thử (Unit Tests) - Telemetry API

Tài liệu này hướng dẫn cách cài đặt, chạy các ca kiểm thử tự động (unit tests) và kiểm thử thủ công cho ứng dụng Telemetry API.

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

## 2. Cách chạy kiểm thử tự động (Unit Tests)

Tùy thuộc vào thư mục hiện tại của bạn trong Terminal:

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
* **Chạy kèm báo cáo Code Coverage:**
  ```powershell
  $env:PYTHONPATH="."
  pytest --cov=telemetry_api telemetry_api
  ```

---

## 3. Các kịch bản kiểm thử đã được tự động hóa

Bộ mã nguồn kiểm thử nằm tại `src/telemetry_api/tests/telemetry_api/test_ingest_api.py` bao gồm các kịch bản quan trọng sau:

1. **`test_valid_payload_returns_201_and_writes_jsonl`**: Kiểm tra gói tin hợp lệ được lưu đúng định dạng vào file log cục bộ (`telemetry.jsonl`) và trả về HTTP `201 Created`.
2. **`test_missing_required_fields_return_400`**: Kiểm tra API từ chối (`400 Bad Request`) nếu thiếu bất kỳ trường bắt buộc nào (`ts`, `tenant_id`, `service_id`, `metric_type`, `value`).
3. **`test_tenant_header_body_mismatch_returns_400`**: Đảm bảo bảo mật bằng cách từ chối request nếu header `X-Tenant-Id` không trùng khớp với trường `tenant_id` trong JSON body.
4. **`test_payload_too_large_returns_413`**: Kiểm tra middleware chặn các request có dung lượng vượt ngưỡng giới hạn cho phép và trả về lỗi `413 Payload Too Large`.
5. **`test_sensitive_label_returns_400` / `test_high_cardinality_label_returns_400`**: Xác thực bộ lọc an toàn thông tin (PII) và ngăn chặn lưu trữ các key có độ phân tán cao (cardinality lớn như `request_id`).
6. **`test_missing_correlation_id_auto_generates_uuid`**: Kiểm tra xem hệ thống có tự sinh mã định danh duy nhất (UUID) để trace log khi client không truyền header `X-Correlation-Id` hay không.

---

## 4. Hướng dẫn kiểm thử thủ công (Manual Testing)

Nếu bạn muốn chạy ứng dụng cục bộ và gửi request kiểm thử bằng công cụ ngoài:

### Bước 1: Khởi chạy Uvicorn Server cục bộ
```powershell
$env:PYTHONPATH="src"
python -m uvicorn telemetry_api.main:app --reload --port 8000
```
*Server sẽ lắng nghe tại: `http://127.0.0.1:8000`*

### Bước 2: Gửi Request kiểm thử

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

* **Gửi Request lỗi (Thiếu trường bắt buộc - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00Z",
          "tenant_id": "demo-tenant-001",
          "service_id": "payment-gateway"
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "Missing required field: metric_type")*

* **Gửi Request lỗi (Không khớp Tenant ID - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00Z",
          "tenant_id": "hacker-tenant-999",
          "service_id": "payment-gateway",
          "metric_type": "api_latency_ms",
          "value": 450.5
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "X-Tenant-Id does not match body tenant_id")*

* **Gửi Request lỗi (Chứa thông tin nhạy cảm PII hoặc Cardinality cao trong Labels - PowerShell):**
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
            "password": "mysecretpassword"
          }
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "label 'password' contains sensitive data marker")*

* **Gửi Request lỗi (Payload quá lớn - PowerShell):**
  ```powershell
  try {
      # Tạo ra một body chuỗi dung lượng lớn hơn 64KB (đọc cấu hình tối đa)
      $largeString = "A" * 70000
      $body = @{
          ts = "2026-06-25T10:30:00Z"
          tenant_id = "demo-tenant-001"
          service_id = "payment-gateway"
          metric_type = "api_latency_ms"
          value = 450.5
          large_field = $largeString
      } | ConvertTo-Json

      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body $body
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 413: "Request payload exceeds max allowed size")*

