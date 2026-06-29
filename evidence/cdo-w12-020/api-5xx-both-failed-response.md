# Bằng chứng HTTP 503 Both Failed Response

Bằng chứng phản hồi từ API khi cả hai cơ chế đẩy sang AMP và ghi S3 failure buffer đều thất bại (ví dụ: mất kết nối hoàn toàn).

## 1. Yêu cầu gửi dữ liệu (Ingest payload)

```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: cdo-w12-020-demo-002" \
  -d '{
    "ts": "2026-06-29T10:45:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "region": "us-east-1"
    }
  }'
```

## 2. Kết quả phản hồi từ API (HTTP 503 Service Unavailable)

```json
{
  "error": "ingest_failed",
  "message": "AMP delivery failed and S3 failure buffer failed: Simulated S3 write failure",
  "event_id": "evt_bcde12345678",
  "request_id": "cdo-w12-020-demo-002",
  "correlation_id": "cdo-w12-020-demo-002"
}
```

## 3. Nhật ký hệ thống (Application Logs)

```json
{"timestamp": "2026-06-29T10:45:00.100Z", "level": "INFO", "event": "telemetry_ingest_received", "correlation_id": "cdo-w12-020-demo-002"}
{"timestamp": "2026-06-29T10:45:00.120Z", "level": "WARNING", "event": "amp_delivery_retry", "event_id": "evt_bcde12345678", "correlation_id": "cdo-w12-020-demo-002", "attempt": 1, "max_retries": 3, "error_type": "HTTP_500"}
{"timestamp": "2026-06-29T10:45:01.200Z", "level": "WARNING", "event": "amp_delivery_retry", "event_id": "evt_bcde12345678", "correlation_id": "cdo-w12-020-demo-002", "attempt": 2, "max_retries": 3, "error_type": "HTTP_500"}
{"timestamp": "2026-06-29T10:45:03.300Z", "level": "ERROR", "event": "amp_delivery_failed_after_retry", "event_id": "evt_bcde12345678", "correlation_id": "cdo-w12-020-demo-002", "error_type": "HTTP_500"}
{"timestamp": "2026-06-29T10:45:03.350Z", "level": "ERROR", "event": "s3_failure_buffer_write_failed", "event_id": "evt_bcde12345678", "correlation_id": "cdo-w12-020-demo-002", "error_type": "RuntimeError"}
{"timestamp": "2026-06-29T10:45:03.360Z", "level": "WARNING", "event": "telemetry_ingest_rejected", "correlation_id": "cdo-w12-020-demo-002", "status_code": 503, "reason": "amp_and_s3_failed"}
```
