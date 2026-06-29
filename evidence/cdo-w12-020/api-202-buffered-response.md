# Bằng chứng HTTP 202 Buffered Response

Bằng chứng phản hồi từ API khi thực hiện ghi nhận telemetry hợp lệ nhưng không thể đẩy sang AMP (gặp lỗi mạng tạm thời) và tự động lưu vào S3 failure buffer.

## 1. Yêu cầu gửi dữ liệu (Ingest payload)

```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: cdo-w12-020-demo-001" \
  -d '{
    "ts": "2026-06-29T10:44:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "region": "us-east-1"
    }
  }'
```

## 2. Kết quả phản hồi từ API (HTTP 202 Accepted)

```json
{
  "status": "buffered",
  "event_id": "evt_38370bd22d1e",
  "request_id": "cdo-w12-020-demo-001",
  "correlation_id": "cdo-w12-020-demo-001",
  "buffer": "s3",
  "idempotency_key": "4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f"
}
```

## 3. Nhật ký hệ thống (Application Logs)

Nhật ký hệ thống hiển thị rõ ràng 3 nỗ lực gửi tới AMP thất bại (1 lần đầu + 2 lần retry), sau đó lưu thành công vào S3 failure buffer:

```json
{"timestamp": "2026-06-29T10:44:00.123Z", "level": "INFO", "event": "telemetry_ingest_received", "correlation_id": "cdo-w12-020-demo-001"}
{"timestamp": "2026-06-29T10:44:00.150Z", "level": "WARNING", "event": "amp_delivery_retry", "event_id": "evt_38370bd22d1e", "correlation_id": "cdo-w12-020-demo-001", "attempt": 1, "max_retries": 3, "error_type": "HTTP_500"}
{"timestamp": "2026-06-29T10:44:01.200Z", "level": "WARNING", "event": "amp_delivery_retry", "event_id": "evt_38370bd22d1e", "correlation_id": "cdo-w12-020-demo-001", "attempt": 2, "max_retries": 3, "error_type": "HTTP_500"}
{"timestamp": "2026-06-29T10:44:03.350Z", "level": "ERROR", "event": "amp_delivery_failed_after_retry", "event_id": "evt_38370bd22d1e", "correlation_id": "cdo-w12-020-demo-001", "error_type": "HTTP_500"}
{"timestamp": "2026-06-29T10:44:03.410Z", "level": "INFO", "event": "s3_failure_buffer_write_success", "event_id": "evt_38370bd22d1e", "correlation_id": "cdo-w12-020-demo-001", "idempotency_key": "4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f", "bucket": "cdo-telemetry-failure-buffer", "object_key": "telemetry-failures/tenant_id=demo-tenant-001/service_id=payment-gateway/metric_type=api_latency_ms/date=2026-06-29/idempotency_key=4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f.json"}
```
