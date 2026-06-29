# S3 Buffer Object Example

Ví dụ cấu trúc nội dung bản ghi (JSON object) được lưu trữ trong S3 Failure Buffer. Bản ghi này đóng gói đầy đủ payload gốc và metadata phục vụ cho việc chuẩn đoán lỗi và tự động replay.

```json
{
  "event_id": "evt_38370bd22d1e",
  "request_id": "cdo-w12-020-demo-001",
  "correlation_id": "cdo-w12-020-demo-001",
  "idempotency_key": "4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f",
  "failed_at": "2026-06-29T10:44:03Z",
  "failure_reason": "amp_delivery_failed_after_retry",
  "retry_count": 3,
  "source": "telemetry-api",
  "payload": {
    "ts": "2026-06-29T10:44:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "region": "us-east-1"
    }
  }
}
```
