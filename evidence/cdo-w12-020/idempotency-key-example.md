# Bằng chứng sinh khóa Idempotency ổn định (Deterministic Key)

Để đảm bảo không bao giờ sinh trùng lặp hoặc sinh sai khóa khi các nhãn (labels) bị thay đổi thứ tự khai báo, thuật toán đã thực hiện sắp xếp lại (sorting) các khóa nhãn trước khi hash.

## 1. Payload 1 (Thứ tự nhãn: region -> env -> service_tier)

```json
{
  "ts": "2026-06-29T10:44:00Z",
  "tenant_id": "demo-tenant-001",
  "service_id": "payment-gateway",
  "metric_type": "api_latency_ms",
  "value": 450.5,
  "labels": {
    "region": "us-east-1",
    "env": "production",
    "service_tier": "gold"
  }
}
```

- **Mã Hash sinh ra:** `d7a5b3c5a610f63901b0f15c7e112d8a4386e812d4db6d9d1461f67f9e8a719a`

## 2. Payload 2 (Thứ tự nhãn: service_tier -> env -> region)

```json
{
  "ts": "2026-06-29T10:44:00Z",
  "tenant_id": "demo-tenant-001",
  "service_id": "payment-gateway",
  "metric_type": "api_latency_ms",
  "value": 450.5,
  "labels": {
    "service_tier": "gold",
    "env": "production",
    "region": "us-east-1"
  }
}
```

- **Mã Hash sinh ra:** `d7a5b3c5a610f63901b0f15c7e112d8a4386e812d4db6d9d1461f67f9e8a719a`

## Kết luận

Hai payload có nhãn khác nhau về thứ tự chèn phần tử nhưng cùng nội dung đã sinh ra **khóa Idempotency giống nhau hoàn toàn (`k1 == k2`)**. Điều này bảo vệ AMP khỏi việc nhận dữ liệu trùng lặp khi replay.
```python
# Kết quả từ test case trong src/telemetry_api/tests/telemetry_api/test_idempotency.py
def test_different_label_orders_generate_same_key() -> None:
    ...
    assert k1 == k2  # PASSED
```
