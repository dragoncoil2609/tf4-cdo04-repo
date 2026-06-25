<!-- ĐÂY LÀ BẢN NHÁP CỦA security_design.md - SAU NÀY SAU KHI ĐƯỢC REVIEW SẼ XÓA -->
<!-- KHÔNG CẦN THÊM GÌ VÀO ĐÂY -->


# Security Design Evidence - TF4 Foresight Lens · CDO-04

**File chính được giải thích:** `docs/03_security_design.md`  
**Infra source of truth:** `docs/02_infra_design.md`  
**Mục đích:** giải thích security design, lý do chọn từng control, trade-off, cost optimization và chuẩn bị câu trả lời khi mentor review.

---

## 1. Tóm tắt cực ngắn

Security design của CDO-04 bảo vệ toàn bộ luồng:

```text
Service/k6 gửi metric
→ ALB /v1/ingest
→ ECS telemetry-ingest validate schema
→ Timestream lưu metric
→ EventBridge tạo job mỗi 5 phút
→ SQS/DLQ giữ prediction job
→ ECS prediction-worker query metric
→ gọi AI POST /v1/predict
→ ghi DynamoDB audit log
→ gửi SNS/CloudWatch/Grafana evidence
→ fallback static threshold nếu AI lỗi
```

Ý chính:

> Platform không chỉ chạy được, mà còn kiểm soát được ai gọi vào, service nào được quyền làm gì, dữ liệu có mã hóa không, prediction có audit log không, và khi AI lỗi thì hệ thống có fallback không.

---

## 2. File `03_security_design.md` đang bảo vệ cái gì?

Platform CDO-04 có các thành phần chính:

| Thành phần | Vai trò | Security cần bảo vệ |
|---|---|---|
| ALB `/v1/ingest` | Cổng nhận telemetry | HTTPS, tenant header, không expose ECS trực tiếp |
| ECS `telemetry-ingest` | Validate metric, ghi Timestream | Private subnet, IAM chỉ được write metric |
| Amazon Timestream | Lưu time-series metric | Encryption, query có tenant/service filter |
| EventBridge | Tạo prediction job định kỳ | Schedule rõ, ít quyền |
| SQS + DLQ | Queue prediction job và retry | Encryption, worker-only consume |
| ECS `prediction-worker` | Query metric, gọi AI, audit, alert, fallback | Private subnet, least privilege role |
| AI `/v1/predict` | AI team cung cấp prediction | HTTPS, token từ Secrets Manager, timeout/fallback |
| DynamoDB audit log | Lưu mọi prediction/fallback | SSE, TTL 90 ngày, GSI evidence |
| S3 evidence | Lưu snapshot bằng chứng | SSE-S3/SSE-KMS, lifecycle |
| SNS/Slack/Email | Gửi cảnh báo | Chỉ worker được publish |
| CloudWatch | Logs/metrics/alarms | Retention, không log secret |
| Secrets Manager | Lưu token/webhook | Không hardcode, IAM-controlled access |

---

## 3. Giải thích từng section trong `03_security_design.md`

### 3.1 Section 1 - Phạm vi bảo mật

Section này trả lời:

> Tài liệu security này cover phần nào, không cover phần nào?

Nó cover phần CDO thật sự cấu hình:

- network;
- IAM;
- secrets;
- encryption;
- audit log;
- tenant isolation;
- schema allowlist;
- PII handling;
- incident/fallback.

Nó không cover:

- SIEM enterprise đầy đủ;
- multi-region active-active;
- auto-remediation;
- app authN/authZ sâu;
- PCI cardholder data.

Lý do: capstone TF4 là prediction + recommendation, không phải production compliance audit đầy đủ.

---

### 3.2 Section 2 - Security View của kiến trúc

Section này vẽ lại kiến trúc từ góc nhìn bảo mật.

Điểm quan trọng nhất:

```text
Chỉ ALB là public entry point.
ECS tasks nằm private.
Ingest service chỉ ghi metric.
Worker chỉ query metric, gọi AI, ghi audit, gửi alert.
```

Tại sao cần section này?

Vì mentor có thể hỏi:

> "Luồng dữ liệu đi qua đâu? Chỗ nào public? Chỗ nào private? Ai được ghi vào database?"

Câu trả lời:

> Public boundary duy nhất là ALB `/v1/ingest`. `telemetry-ingest` và `prediction-worker` chạy private. Timestream/DynamoDB/SQS/S3 không expose public app endpoint, truy cập bằng IAM role.

---

### 3.3 Section 3 - Network Security

Network security trả lời:

> Người ngoài gọi vào hệ thống bằng đường nào? Có gọi thẳng ECS task được không?

Thiết kế:

- ALB nhận HTTPS `/v1/ingest`.
- ECS `telemetry-ingest` nằm private, chỉ ALB gọi được.
- ECS `prediction-worker` nằm private, không cần public inbound.
- Worker outbound tới Timestream, DynamoDB, SQS, S3, SNS, Secrets Manager, AI endpoint.
- Nếu AI team expose được private path, ưu tiên gọi qua VPC Endpoint/PrivateLink.

Trade-off:

| Option | Ưu điểm | Nhược điểm |
|---|---|---|
| Public ALB cho `/v1/ingest` | Dễ demo, k6/Locust gọi từ ngoài được | Cần kiểm soát bằng HTTPS, tenant token, schema validation |
| Internal ALB | An toàn hơn | Demo khó hơn nếu producer không chạy trong VPC |

Quyết định hiện tại:

> Public ALB cho demo có kiểm soát; ECS tasks vẫn private. Sau này có thể đổi thành internal ALB nếu producer chạy trong VPC.

---

### 3.4 Section 4 - IAM & Access Control

IAM trả lời:

> Service nào được quyền làm gì trong AWS?

Nguyên tắc:

> Không đưa chìa khóa tổng cho service. Mỗi role chỉ được quyền đúng việc.

Role chính:

| Role | Dùng bởi | Ý nghĩa dễ hiểu |