# CDO-W12-020 — Verification Evidence Index

Thư mục này chứa toàn bộ bằng chứng kiểm thử (evidence) cho chức năng S3 Failure Buffer của Telemetry API.

## Mục lục bằng chứng

1. **[api-202-buffered-response.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-020/api-202-buffered-response.md)**
   - Phản hồi HTTP `202 Accepted` khi gửi dữ liệu tới AMP lỗi và S3 failure buffer ghi thành công.

2. **[api-5xx-both-failed-response.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-020/api-5xx-both-failed-response.md)**
   - Phản hồi HTTP `503 Service Unavailable` khi cả AMP và S3 failure buffer đều gặp sự cố.

3. **[s3-buffer-object-example.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-020/s3-buffer-object-example.md)**
   - Ví dụ cấu trúc file JSON được lưu trong S3 failure buffer với đầy đủ metadata và payload gốc.

4. **[s3-object-metadata-example.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-020/s3-object-metadata-example.md)**
   - Ví dụ các HTTP Headers metadata được gắn vào S3 Object (như `idempotency-key`, `event-id`, `correlation-id`).

5. **[idempotency-key-example.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-020/idempotency-key-example.md)**
   - Bằng chứng thuật toán sinh khóa Idempotency ổn định (deterministic) khi thay đổi thứ tự labels.

6. **[cloudwatch-alarm-object-age.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-020/cloudwatch-alarm-object-age.md)**
   - Trạng thái cấu hình CloudWatch Alarm kiểm soát tuổi thọ file lỗi trong S3 vượt ngưỡng 300 giây.

7. **[replay-result.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-020/replay-result.md)**
   - Bằng chứng thực thi Replay quét file lỗi từ S3, gửi lại AMP thành công và tự động dọn dẹp (xóa file).
