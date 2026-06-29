# Evidence Directory - Task CDO-W12-019

Thư mục này lưu trữ bằng chứng tích hợp (evidence) cho việc cấu hình và kiểm thử đường đi telemetry remote_write từ Telemetry Ingest API vào Amazon Managed Service for Prometheus (AMP).

## Danh sách file bằng chứng
1. **[promql-query-result.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-019/promql-query-result.md):** Kết quả truy vấn PromQL trên AMP kiểm thử metric `api_latency_ms`.
2. **[cloudwatch-adot-remote-write-log.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-019/cloudwatch-adot-remote-write-log.md):** Log CloudWatch xác thực ADOT Collector đẩy metric lên AMP remote_write thành công.
3. **[amp-workspace-screenshot-note.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-019/amp-workspace-screenshot-note.md):** Chi tiết cấu hình workspace AMP đang active trên AWS.
4. **[iam-role-policy-note.md](file:///d:/XBrain%20x%20AWS%20Accelerator%20Internship%20Program/PHASE%20-%20II/tf4-cdo04-repo/evidence/cdo-w12-019/iam-role-policy-note.md):** Ghi nhận cấu hình IAM Role Task cho phép `aps:RemoteWrite` bằng SigV4 (không dùng token lâu dài).
