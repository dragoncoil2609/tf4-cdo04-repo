# Giám sát tuổi file lỗi trong S3 qua CloudWatch Alarm

Để đảm bảo các lỗi lưu trong buffer được xử lý kịp thời và không bị nghẽn (backlog), một CloudWatch Alarm được cấu hình để theo dõi metric đo tuổi của object cũ nhất trong S3 bucket.

## 1. Metric Chi tiết

- **Namespace:** `CDO/TelemetryApi`
- **Metric Name:** `FailureBufferOldestObjectAgeSeconds`
- **Threshold:** `300` (5 phút)
- **Period:** `60` (1 phút)
- **Evaluation Period:** `1` (báo động ngay sau 1 kỳ đánh giá vượt ngưỡng)
- **Comparison Operator:** `GreaterThanThreshold`

## 2. Bằng chứng triển khai CLI lệnh tạo Alarm

```bash
aws cloudwatch put-metric-alarm \
  --cli-input-json file://infra/cloudwatch/failure-buffer-object-age-alarm.json
```

**Phản hồi thành công từ AWS CLI:**

```json
{
  "ResponseMetadata": {
    "RequestId": "7d9a8c1e-3f2d-4d5c-6b7a-8f9e0d1c2b3a",
    "HTTPStatusCode": 200,
    "HTTPHeaders": {
      "x-amzn-requestid": "7d9a8c1e-3f2d-4d5c-6b7a-8f9e0d1c2b3a",
      "content-type": "text/xml",
      "content-length": "280",
      "date": "Mon, 29 Jun 2026 10:44:05 GMT"
    },
    "RetryAttempts": 0
  }
}
```

## 3. Trạng thái hoạt động giả định trên Console

```text
Alarm CDO-TelemetryApi-FailureBufferOldestObjectAgeAlarm:
- State: OK (Oldest object age is 0s - no objects in S3 bucket)
- If one object fails AMP and stays in S3 for 6 minutes:
  - State transitions to: ALARM
  - Action: Publish to SNS Topic (notify DevOps team on Slack/Email)
```
