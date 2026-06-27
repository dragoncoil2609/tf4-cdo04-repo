# Hạ tầng

Thư mục gốc cho Terraform IaC của CDO-04 SLO Early-Warning Control Plane.

## Snapshot quyết định MVP cho Terraform v1

Terraform v1 phải triển khai các quyết định này trước mọi hardening tùy chọn:

| Hạng mục | Quyết định đã chốt |
|---|---|
| Region/account | Một region `us-east-1`; một account với tên resource và state key tách theo môi trường. |
| Cổng vào public | Một public ALB cho `/v1/ingest`; bắt buộc có `allowed_ingress_cidrs` và không có giá trị mặc định mở. |
| HTTPS | HTTPS cho non-sandbox bắt buộc có `acm_certificate_arn` sẵn tại `us-east-1`; Terraform mặc định không tạo Route 53/ACM. |
| Runtime | ECS Fargate Linux/x86 private tasks, `awsvpc`, `assignPublicIp = DISABLED`. |
| Luồng AI | Worker gọi AI qua ECS Service Connect service name; Terraform v1 không tạo internal AI ALB. |
| Ghi metric | ADOT/Prometheus Collector ECS service tự quản lý, scrape 60 giây, SigV4 `remote_write` tới AMP. |
| AMP endpoints | MVP dùng NAT cho AMP HTTPS. Nếu bật `aps-workspaces` PrivateLink cho data-plane remote_write/query thì phải bật thêm regional STS endpoint. `aps` chỉ là control-plane. |
| Queue | EventBridge Scheduler target DLQ và DLQ của prediction source queue. |
| Audit | DynamoDB primary key tenant/service/time, tra cứu prediction GSI, TTL `expires_at_epoch`. |
| Evidence | Ghi audit row cho mọi prediction; S3 evidence object chỉ lưu cho high-risk, fallback hoặc các trường hợp failure/replay. |
| Alerts | CloudWatch alarms gửi tới SNS email; xác nhận subscription làm thủ công. |
| Deployment | ECS rolling deployment circuit breaker cho API, Worker và AI trong v1. ECS-native blue/green là post-MVP; CodeDeploy không thuộc v1. |
| Ngoài phạm vi | WAF, Service Connect TLS/Private CA, bộ interface endpoint đầy đủ, multi-account, multi-region DR. |

### Guardrail quota AMP

Mức 50k events/sec là mục tiêu stress design, không phải mặc định cho Terraform demo. AMP remote_write quota tính theo sample. Docs và test phải đổi events/sec thành samples/sec:

```text
samples/sec = events/sec × số sample phát sinh trên mỗi event
```

Nếu kết quả vượt quota ingest mặc định của AMP, kế hoạch phải yêu cầu tăng quota AMP hoặc giảm trần load test. Ví dụ 50k events/sec × 7 samples/event = 350k samples/sec, cao hơn ingest rate mặc định 70k samples/sec.

### Ghi chú topology theo contract

`deployment-contract.md` mô tả lựa chọn internal ALB/private DNS cho AI Engine. CDO Terraform v1 cố ý dùng ECS Service Connect thay thế. Cách này vẫn giữ đúng ý định đã chốt của contract: AI Engine private, không public, giới hạn bằng SG và chỉ CDO Worker được gọi. Không sửa contract file.

## Tài liệu nguồn bắt buộc đọc

Đọc các tài liệu này trước khi viết Terraform:

- [`../docs/01_requirements_analysis.md`](../docs/01_requirements_analysis.md)
- [`../docs/02_infra_design.md`](../docs/02_infra_design.md)
- [`../docs/03_security_design.md`](../docs/03_security_design.md)
- [`../docs/04_deployment_design.md`](../docs/04_deployment_design.md)
- [`../docs/05_cost_analysis.md`](../docs/05_cost_analysis.md)
- [`../docs/08_adrs.md`](../docs/08_adrs.md)
- [`../docs/vpce_vs_nat_cost_notes.md`](../docs/vpce_vs_nat_cost_notes.md)
- [`../contracts/ai-api-contract.md`](../contracts/ai-api-contract.md)
- [`../contracts/telemetry-contract.md`](../contracts/telemetry-contract.md)
- [`../contracts/deployment-contract.md`](../contracts/deployment-contract.md)

`deployment-contract.md` mô tả pattern internal ALB/private DNS cho AI Engine. CDO Terraform v1 cố ý giữ cùng mục tiêu private/không public bằng ECS Service Connect để tránh thêm chi phí ALB và khớp thiết kế CDO hiện tại.

## Layout dự kiến

```text
infra/
├── bootstrap/             # S3 backend, KMS nếu dùng, GitHub OIDC provider, Terraform deploy role
├── terraform/             # Terraform root chính
│   ├── modules/
│   │   ├── networking/    # VPC, subnets, SGs, 1 NAT, S3/DynamoDB Gateway Endpoints
│   │   ├── data/          # AMP, DynamoDB, SQS/DLQs, S3 evidence, SSM/Secrets/SNS
│   │   ├── compute/       # ALB, ECR, ECS Cluster/Services, Service Connect, Scheduler
│   │   └── observability/ # CloudWatch Logs/Metrics/Dashboard/Alarms, Budget
│   ├── versions.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
└── README.md
```

Hiện chưa có file Terraform. Chỉ tạo skeleton sau khi các quyết định ở trên được chấp nhận.
