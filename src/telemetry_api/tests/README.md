# Hướng Dẫn Chạy Kiểm Thử (Unit Tests) & Metrics - Telemetry API

Tài liệu này hướng dẫn cách chạy các ca kiểm thử tự động (unit tests) và kiểm thử thủ công cho ứng dụng Telemetry API bao gồm các tính năng nâng cấp Schema Validation (CDO-W12-016), PII / Label Denylist (CDO-W12-017), Metric Allowlist (CDO-W12-018) và /health endpoint (CDO-W12-021).

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

## 3. Các kịch bản kiểm thử đã được tự động hóa (94 Test Cases)

Bộ mã nguồn kiểm thử nằm tại `src/telemetry_api/tests/telemetry_api/test_ingest_api.py` bao gồm 94 kịch bản quan trọng sau:

1. **`test_valid_payload_returns_201_and_writes_jsonl`**: Kiểm tra gói tin hợp lệ được chấp nhận và ghi đúng định dạng vào file log cục bộ (`telemetry.jsonl`).
2. **`test_metrics_endpoint_initial_state` / `test_accepted_request_increments_metric`**: Đảm bảo bộ đếm `/metrics` phản ánh đúng các request thành công và thất bại.
3. **`test_timestamp_validation`**: Chỉ cho phép định dạng RFC3339 UTC kết thúc bằng `Z` hoặc offset không đổi lệch 0.
4. **`test_value_validation` / `test_nan_infinity_value_validation`**: Đảm bảo giá trị metric bắt buộc phải là số thực hoặc số nguyên.
5. **`test_non_empty_string_fields`**: Các trường text định danh phải là kiểu chuỗi và không được để trống hoặc chỉ có khoảng trắng.
6. **`test_labels_validation`**: Kiểm tra các ràng buộc kiểu nhãn labels phẳng, cấm lồng nhau (nested dicts/arrays).
7. **`test_pii_denylist_keys`**: Đảm bảo toàn bộ 10 keys cấm PII đều bị từ chối với HTTP 400.
8. **`test_high_cardinality_keys`**: Đảm bảo các key có cardinality cao bị chặn.
9. **`test_raw_path_with_ids_values`**: Kiểm thử phát hiện path chứa ID động.
10. **`test_pii_and_cardinality_rejection_storage_protection`**: Chứng minh các request vi phạm PII/Cardinality tuyệt đối không được ghi vào file JSONL.
11. **`test_pii_and_cardinality_metrics_increments`**: Xác nhận các bộ đếm `telemetry_ingest_pii_rejected_total` và `telemetry_ingest_cardinality_rejected_total` tăng chính xác.
12. **`test_pii_denylist_logging_and_response_no_leak`**: Đảm bảo thông tin email thô nhạy cảm không bị lộ ra cả JSON response lẫn logs hệ thống.
13. **`test_allowlisted_metrics_success`**: Đảm bảo cả 7 AI signals trong contract đều được chấp nhận khi có đủ nhãn bắt buộc.
14. **`test_unsupported_metrics_rejected`**: Các metric ngoài allowlist bị từ chối 400 và tăng metric `telemetry_ingest_unsupported_metric_rejected_total`.
15. **`test_internal_only_metrics_rejected`**: Các metric nội bộ (`error_rate` và `oldest_message_age_seconds`) bị chặn với lý do `internal_only_metric_not_ai_signal`.
16. **`test_missing_required_labels`**: Thiếu nhãn bắt buộc theo đặc tả của metric bị chặn và tăng `telemetry_ingest_metric_label_rejected_total`.
17. **`test_required_label_empty_or_whitespace`**: Nhãn bắt buộc truyền lên nhưng giá trị rỗng/khoảng trắng bị từ chối.
18. **`test_metric_rejections_do_not_write_to_storage`**: Đảm bảo các request bị chặn do chính sách metric/nhãn tuyệt đối không ghi file.
19. **`test_metric_rejection_logging_structured`**: Kiểm tra logs ghi nhận đầy đủ lý do từ chối metric/labels và correlation_id kèm trường `missing_label`.
20. **`test_health_endpoint_returns_200`**: Kiểm tra endpoint `/health` trả HTTP 200 kèm các thông tin metadata tối giản: status, service, version, environment, build_id hoặc commit_sha.
21. **`test_health_does_not_leak_secrets`**: Xác nhận response của `/health` không rò rỉ bất kỳ thông tin nhạy cảm nào (secret, token, password, authorization, credentials, database urls, api keys).
22. **`test_health_does_not_mutate_storage`**: Xác nhận gọi `/health` hoàn toàn độc lập và không thay đổi/ghi dữ liệu vào file lưu trữ.

---

## 4. Hướng dẫn kiểm thử thủ công (Manual Testing)

### Bước 1: Khởi chạy Uvicorn Server cục bộ
```powershell
$env:PYTHONPATH="src"
python -m uvicorn telemetry_api.main:app --reload --port 8000
```
*Server sẽ lắng nghe tại: `http://127.0.0.1:8000`*

### Bước 2: Kiểm tra Health Endpoint
Gửi request GET đến `/health`:
```powershell
Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8000/health"
```
**Phản hồi kỳ vọng:**
```json
{
  "status": "ok",
  "service": "telemetry-api",
  "version": "0.1.0",
  "build_id": "local",
  "commit_sha": "unknown",
  "environment": "local"
}
```

### Bước 3: Gửi Request kiểm thử Ingest & Metrics

* **Gửi Request hợp lệ (PowerShell):**
  ```powershell
  Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
    -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
    -Body '{
      "ts": "2026-06-25T10:30:00Z",
      "tenant_id": "demo-tenant-001",
      "service_id": "payment-gw",
      "metric_type": "api_latency_ms",
      "value": 450.5,
      "labels": { "region": "us-east-1" }
    }'
  ```

* **Gửi Request lỗi (Metric ngoài allowlist - `random_metric` - PowerShell):**
  ```powershell
  try {
      Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/v1/ingest" `
        -Headers @{ "X-Tenant-Id" = "demo-tenant-001"; "Content-Type" = "application/json" } `
        -Body '{
          "ts": "2026-06-25T10:30:00Z",
          "tenant_id": "demo-tenant-001",
          "service_id": "payment-gw",
          "metric_type": "random_metric",
          "value": 100,
          "labels": { "region": "us-east-1" }
        }'
  } catch {
      $_.Exception.Response
  }
  ```
  *(Trả về HTTP 400: "metric_type is not in AI signal allowlist: random_metric")*

### Bước 4: Kiểm tra lại Metrics sau khi gửi các request
```powershell
Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8000/metrics"
```
