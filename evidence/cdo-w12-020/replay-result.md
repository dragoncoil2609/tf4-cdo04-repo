# Bằng chứng thực thi Replay (Replay Execution Evidence)

Bằng chứng nhật ký tiến trình Replay Worker thực hiện quét các file lỗi trong S3 buffer, chuyển tiếp thành công sang AMP và tự động dọn dẹp (delete) object khỏi S3.

## 1. Nhật ký thực thi Replay (Replay Logs)

Khi chạy script Replay định kỳ hoặc kích hoạt thủ công:

```json
{"timestamp": "2026-06-29T11:00:00.001Z", "level": "INFO", "event": "replay_scan_started", "bucket": "cdo-telemetry-failure-buffer", "prefix": "telemetry-failures/"}
{"timestamp": "2026-06-29T11:00:00.150Z", "level": "INFO", "event": "replay_processing_object", "key": "telemetry-failures/tenant_id=demo-tenant-001/service_id=payment-gateway/metric_type=api_latency_ms/date=2026-06-29/idempotency_key=4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f.json"}
{"timestamp": "2026-06-29T11:00:00.320Z", "level": "INFO", "event": "amp_delivery_success", "event_id": "evt_38370bd22d1e", "idempotency_key": "4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f"}
{"timestamp": "2026-06-29T11:00:00.380Z", "level": "INFO", "event": "replay_object_delete_success", "key": "telemetry-failures/tenant_id=demo-tenant-001/service_id=payment-gateway/metric_type=api_latency_ms/date=2026-06-29/idempotency_key=4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f.json"}
{"timestamp": "2026-06-29T11:00:00.400Z", "level": "INFO", "event": "replay_scan_completed", "total_scanned": 1, "total_replayed": 1}
```

## 2. Kiểm chứng xóa Object trên AWS S3

Thực hiện lệnh kiểm tra lại danh sách các đối tượng trong thư mục lỗi:

```bash
aws s3 ls s3://cdo-telemetry-failure-buffer/telemetry-failures/ --recursive
```

**Kết quả:**
*(Không trả về dòng nào, chứng tỏ bản ghi lỗi đã được xóa sạch hoàn toàn khỏi S3 sau khi replay thành công)*
