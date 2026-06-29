# S3 Object Metadata Headers

Bằng chứng/mô tả các User-defined metadata headers đi kèm với S3 Object để hỗ trợ lọc, truy vấn nhanh mà không cần tải nội dung JSON của file.

Khi API gọi `s3_client.put_object`, các metadata header sau được thiết lập:

| HTTP Header (Metadata Key) | Giá trị ví dụ | Ý nghĩa |
| :--- | :--- | :--- |
| `x-amz-meta-idempotency-key` | `4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f` | Khóa idempotency dùng để chống trùng lặp dữ liệu khi replay. |
| `x-amz-meta-event-id` | `evt_38370bd22d1e` | Định danh sự kiện ngẫu nhiên sinh ra cho bản ghi. |
| `x-amz-meta-correlation-id` | `cdo-w12-020-demo-001` | ID liên kết của yêu cầu HTTP gốc để trace log chéo hệ thống. |
| `x-amz-meta-retry-count` | `3` | Số lần thử lại tối đa được thực hiện trước khi quyết định đưa vào buffer. |

## AWS CLI Verification Command

Để xem metadata của một object cụ thể trên AWS S3:

```bash
aws s3api head-object \
  --bucket cdo-telemetry-failure-buffer \
  --key telemetry-failures/tenant_id=demo-tenant-001/service_id=payment-gateway/metric_type=api_latency_ms/date=2026-06-29/idempotency_key=4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f.json
```

**Output phản hồi từ AWS S3:**

```json
{
  "AcceptRanges": "bytes",
  "LastModified": "Mon, 29 Jun 2026 10:44:03 GMT",
  "ContentLength": 418,
  "ETag": "\"a98098ad8e6c7890987f6543ea123456\"",
  "ContentType": "application/json",
  "ServerSideEncryption": "aws:kms",
  "SSEKMSKeyId": "arn:aws:kms:us-east-1:123456789012:key/abc-123-xyz",
  "Metadata": {
    "idempotency-key": "4c8f58b8f2c349195b00c3b53c7a72d3e38714e82df4386e812d4db6d9d1461f",
    "event-id": "evt_38370bd22d1e",
    "correlation-id": "cdo-w12-020-demo-001",
    "retry-count": "3"
  }
}
```
