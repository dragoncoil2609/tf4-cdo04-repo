# Deployment & CI/CD Design - Task force 4 · CDO 04

<!-- Doc owner: Nguyễn Văn Huy Hoàng (Hoàng)
     Status: Refined (W11 T4)
     Word target: 1200-2000 từ -->

## 1. IaC strategy

### 1.1 Tool choice

- **IaC tool**: **Terraform (v1.10+)**
- **Deployment region/runtime**: CDO-04 deploy tại `us-east-1` với ECS Fargate Linux/x86 cho Telemetry API, Prediction Worker và AI Engine.
  - **Lý do lựa chọn**: Terraform cung cấp cơ chế quản lý trạng thái hạ tầng mạnh mẽ, thư viện tài nguyên phong phú trên AWS, hỗ trợ viết code dạng khai báo (declarative) giúp dễ dàng theo dõi và tái sử dụng qua các module.
- **State backend**: **Amazon S3** remote backend với native lockfile (`use_lockfile = true`). Thiết kế mới **không tạo DynamoDB lock table** vì Terraform S3 native locking đã đủ cho workflow này và giữ bootstrap đơn giản.
- **GitHub OIDC bootstrap**: `infra/bootstrap/` khởi tạo **GitHub Actions OIDC provider** và backend role tối thiểu cho CI/CD assume-role. Role bootstrap chỉ truy cập S3 state backend và `sts:GetCallerIdentity`; role deploy chính cho main `terraform plan/apply` là role riêng theo environment.
- **Modular structure**: `infra/bootstrap/` bootstrap backend + GitHub OIDC foundation; `infra/terraform/` là root module chính và gọi các module con (`networking`, `data`, `compute`, `observability`) để tránh flat Terraform khó review.

### 1.2 Module structure

```
infra/
├── bootstrap/             # One-time S3 backend bucket + GitHub OIDC provider/backend role; backend uses use_lockfile=true
├── terraform/             # Terraform root chính for the platform
│   ├── modules/
│   │   ├── networking/    # VPC, public/private subnets, SGs, 1 NAT, S3/DynamoDB Gateway Endpoints
│   │   ├── data/          # AMP workspace, DynamoDB audit/policy, SQS/DLQ, S3 evidence, Secrets/KMS
│   │   ├── compute/       # Public ALB, ECS Cluster, ECS Fargate Services, ECS Service Connect, Scheduler
│   │   └── observability/ # CloudWatch Logs/Metrics/Dashboard/Alarms, SNS/Budget alerting
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
└── README.md
```

### 1.3 State management

- **Remote state**: `infra/bootstrap/` tạo S3 bucket cho Terraform state, bật versioning, encryption và TLS-only bucket policy.
- **State lock**: dùng native S3 lockfile với `use_lockfile = true`; thiết kế này **không dùng DynamoDB lock table**.
- **GitHub OIDC foundation**: `infra/bootstrap/` tạo IAM OIDC provider cho `token.actions.githubusercontent.com` và backend role cho GitHub Actions. Trust policy giới hạn theo đúng GitHub org/repo/branch hoặc environment. Role này chỉ truy cập S3 state backend; role pipeline dùng để chạy main root `terraform plan/apply` phải được cấp riêng theo môi trường.
- **Pipeline integration**: Thực hiện chạy `terraform plan` tự động khi mở Pull Request (PR) và chỉ thực hiện `terraform apply` sau khi PR được merge vào nhánh chính tương ứng.


### 1.4 State keys theo environment cho Terraform v1

Main Terraform root dùng S3 backend với native lockfile và key tách theo môi trường:

```text
tf4-cdo04/sandbox/terraform.tfstate
tf4-cdo04/staging/terraform.tfstate
tf4-cdo04/prod/terraform.tfstate
```

S3 state bucket tách riêng với bucket evidence/failure-buffer. State bucket bật versioning, encryption, Block Public Access và TLS-only bucket policy.

### 1.5 Trình tự bootstrap Terraform v1

1. `infra/bootstrap/` tạo S3 state bucket, GitHub OIDC provider và backend role tối thiểu cho state access.
2. `infra/terraform/` apply phần network/data/observability và ECR repositories.
3. CI build/push image tags vào ECR.
4. `enable_services = true` apply ECS task definitions/services với image tags cụ thể.

Không dùng public image placeholder cho production/demo services.

### 1.6 Ghi chú AI networking theo contract

`contracts/deployment-contract.md` mô tả internal ALB/private DNS cho AI Engine. CDO Terraform Path A không tạo ALB thứ hai; Worker gọi AI qua API Gateway HTTP API `AWS_IAM`, API Gateway dùng VPC Link tới internal ALB listener `:80`, rồi forward tới AI Engine target group. Worker ở private subnet ra API Gateway bằng NAT Gateway hiện có. ECS Service Connect được giữ làm rollback/fallback trong migration. Không sửa contract file.

---

## 2. CI/CD pipeline

### 2.1 Pipeline stages

```
PR opened ──► Doc Check ──► Lint & Validate ──► Test ──► Scan ──► Plan ──► Review ──► Merge ──► Build ──► Plan artifact ──► Manual Approval ──► Apply saved plan ──► Smoke scaffold
```

| Stage | Tool | What it does | Quality gate |
|---|---|---|---|
| Doc Check | Markdown-lint / Script | Kiểm tra tính hoàn thiện và định dạng của tài liệu Markdown | Không có lỗi cú pháp Markdown hoặc link hỏng |
| Lint & Validate | Terraform CLI | Chạy `terraform fmt -check` và `terraform validate` kiểm tra cú pháp IaC | Cú pháp đúng chuẩn declarative và định dạng đồng nhất |
| Build | GitHub Actions | Compile mã nguồn, build Docker image cho Telemetry API, Prediction Worker và AI Engine | Build thành công không có lỗi cú pháp |
| Test | Pytest | Chạy unit test & integration test cho worker và API | Coverage ≥ 80% |
| Scan | Gitleaks + Trivy | Quét secret leak trong mã nguồn và quét lỗ hổng bảo mật image Docker | 0 leak detected, 0 lỗi CRITICAL |
| Plan | Terraform CLI | PR chạy `terraform plan` độc lập với push build/apply; push tạo `tfplan` artifact riêng sau khi image đã build | PR có readable plan; push apply dùng đúng saved plan artifact |
| Review & Merge | GitHub PR | Rà soát chéo code và merge nhánh dựa trên Peer Review Matrix | Ít nhất 1 approval từ Reviewer được chỉ định |
| Manual Approval | GitHub Environments | Tạm dừng chờ Tech Lead phê duyệt trước khi chạy deploy | Trạng thái: Approved (áp dụng bắt buộc với Production) |
| Apply | Terraform CLI | Chạy `terraform apply tfplan` sau GitHub Environment approval; không dùng lock bypass flag | Apply đúng saved plan artifact, state lock bật |
| Smoke | Custom script | Batch 1 chỉ chuẩn bị scaffold trung thực; full smoke/E2E chạy sau khi Batch 0-8 hoàn tất | Không báo green giả; final run mới ghi evidence |
| AMP ingest/query validation | Custom script / PromQL | Xác nhận ADOT Collector sidecar remote_write đã ghi sample vào AMP và Worker query_range trả 1-minute samples đủ 120 phút theo tenant/service/metric. Kiểm tra CloudWatch logs của ADOT container (`/ecs/telemetry-api`, stream prefix `adot-collector`) để xác nhận không có lỗi export/auth. | Có sample mới trong AMP và PromQL trả đủ window trước khi smoke AI |

### 2.2 Branch strategy & Peer Review Matrix

Hệ thống áp dụng mô hình GitFlow rút gọn:
- `main` = Nhánh production ổn định phục vụ buổi demo chính thức.
- `develop` = Nhánh integration phục vụ việc phát triển và kiểm thử liên tục trong W11-W12.
- `feature/*` (ví dụ `Vinh_Terraform`, `NinhHuy_Observability`): Các nhánh tính năng cá nhân tách từ `develop`.
- Yêu cầu bắt buộc: Phải mở Pull Request (PR) và có ít nhất **1 sự phê duyệt (approval)** từ người review được chỉ định trước khi được merge.

#### 👥 Ma trận phân công Peer Review (Peer Review Matrix):
Để tối ưu chất lượng và phân bổ rõ ràng trách nhiệm rà soát chéo giữa các thành viên:

*   **Nguyễn Văn Huy Hoàng (Hoàng - Owner chính phần CI/CD & Deploy):**
    *   Chịu trách nhiệm thiết lập và vận hành CI/CD pipeline.
    *   Chỉ định Reviewer: **Hoàng** sẽ review chính các task của **Tín** (EPIC-05: Security Design) và **Vinh** (EPIC-04: Infrastructure/Terraform Skeleton) / technical ADR.
*   **Ngô Nguyễn Trương An (An):**
    *   Chỉ định Reviewer: **An** sẽ review chính các task của **Ninh** (EPIC-07: Observability/Test/Cost) và **Huy Hoang (Hoàng)** (EPIC-06: Deployment/CI-CD).
*   **Nguyễn Thành Vinh (Vinh):**
    *   Chỉ định Reviewer: **Vinh** sẽ review các task của **Tuấn** (EPIC-03: Infrastructure Design).
*   **Review tài liệu Final (Final Docs):**
    *   Cả **An** và **Hoàng** sẽ cùng đồng duyệt (co-review) để kiểm tra chất lượng và độ chính xác của toàn bộ tài liệu bàn giao cuối cùng trước khi đóng băng code.

### 2.3 Advanced Pipeline Features (Tính năng nâng cao)

1.  **Concurrency Control (Kiểm soát chạy song song):**
    Chặn đụng độ chéo nhánh bằng cách nhóm ở mức workflow. Khi có pipeline mới kích hoạt, pipeline cũ đang chạy dở sẽ tiếp tục chạy đến khi kết thúc (không hủy giữa chừng tránh làm hỏng hạ tầng AWS):
    ```yaml
    concurrency:
      group: ${{ github.workflow }}
      cancel-in-progress: false
    ```
2.  **Dependency Caching (Tối ưu hóa thời gian chạy):**
    Sử dụng cơ chế cache tự động băm của `actions/setup-python` cho pip để rút ngắn thời gian cài đặt thư viện kiểm thử từ 3 phút xuống còn 10 giây:
    ```yaml
    - uses: actions/setup-python@v5
      with:
        python-version: '3.10'
        cache: 'pip'
    ```
3.  **Matrix Build Strategy (Nhân bản Docker Build):**
    Dùng Matrix để build song song Docker images cho cả 3 service demo cùng lúc chỉ với một đoạn cấu hình duy nhất:
    ```yaml
    strategy:
      fail-fast: false
      matrix:
        service: [telemetry-api, prediction-worker, ai-engine]
    ```
4.  **Immutable Image Tagging (Gắn nhãn chống ghi đè):**
    Mọi Docker image đẩy lên Amazon ECR đều được đánh tag theo mã băm Git Commit SHA (`${{ github.sha }}`) để đảm bảo tính bất biến và dễ dàng rollback:
    ```yaml
    tags: |
      ${{ steps.login-ecr.outputs.registry }}/foresight-lens/${{ matrix.service }}:${{ github.sha }}
      ${{ steps.login-ecr.outputs.registry }}/foresight-lens/${{ matrix.service }}:latest
    ```

---

## 3. GitOps & Sync Waves

### 3.1 Tool choice

- **GitHub Actions + ECS rolling deployment circuit breaker**: Terraform v1 dùng GitHub Actions làm điều phối viên và ECS rolling deployment/circuit breaker để quản lý rollout. ECS-native blue/green qua Service Connect là post-MVP; CodeDeploy không nằm trong v1.
- **Repo structure**: Monorepo chứa cả IaC (`infra/`), mã nguồn ứng dụng (`src/`), kịch bản test (`tests/`) và tài liệu (`docs/`).

### 3.2 Sync waves

Trong quá trình khởi tạo môi trường mới thông qua pipeline, các tài nguyên được áp dụng tuần tự theo các đợt (sync waves) để tránh lỗi phụ thuộc:

| Wave | Components | Description |
|---|---|---|
| 0 | Networking (VPC, Subnets, SG) | Hạ tầng mạng cơ bản |
| 1 | Database & Message Queue (DynamoDB, SQS) | Nơi lưu trữ và truyền tin |
| 2 | Observability Core (CloudWatch Logs/Metrics, Dashboard, SNS) | Hạ tầng giám sát và alert sẵn sàng nhận log/metric |
| 3 | Compute Layer (ECS Cluster, Fargate Task Definitions cho Telemetry API, Worker, AI Engine) | Môi trường tính toán chứa container |
| 4 | Ingress + private AI routing | Public `/v1/ingest` đi qua API Gateway HTTP API; Worker gọi AI qua NAT → API Gateway HTTP API `AWS_IAM` → VPC Link → internal ALB `:80` → AI Engine target group. ECS Service Connect giữ làm rollback/fallback. |

---

## 4. Deployment strategy

### 4.1 Strategy

- **Telemetry API và Prediction Worker**: dùng ECS rolling deployment circuit breaker để đơn giản hóa rollout cho workload nội bộ, rollback về task definition ổn định nếu health check hoặc alarm fail.
- **AI Engine trong Terraform v1**: dùng ECS rolling deployment circuit breaker giống API/Worker. API Gateway HTTP API enforce `AWS_IAM`/SigV4; VPC Link + internal ALB listener `:80` xử lý private routing vào AI target group. ECS Service Connect giữ làm rollback/fallback trong migration.
- **Post-MVP hardening**: nếu cần blue/green sau này, ưu tiên ECS-native blue/green với Service Connect. CodeDeploy không thuộc current scope.
- **AI rolling rollback criteria**:
  - Error rate > **1%** trong rollout window.
  - AI p99 latency > **800ms** trong rollout window.
  - Capacity Exhaustion false/deviation > **15%**.
- **Platform/API rollback criteria**:
  - Platform/API p99 > **800ms** trong 5 phút hoặc 5xx > **1%**.
  - Có cảnh báo lỗi từ CloudWatch Metric Alarm gửi về SNS.

### 4.2 Rollback method

- **AI Engine tự động**: ECS deployment circuit breaker rollback về previous task definition nếu deployment mới không đạt steady state hoặc alarm/health check fail.
- **Telemetry API / Prediction Worker tự động**: ECS deployment circuit breaker rollback task definition khi deployment mới không đạt steady state.
- **Thủ công**: Điều hành viên có thể bấm "Rollback" trên AWS Console hoặc trigger qua GitHub Actions để ép buộc rollback ngay lập tức.
- **Target RTO (Recovery Time Objective)**: platform service rollback theo ECS steady-state/circuit-breaker timing. Target trong contract `<60s` vẫn là mục tiêu rollback mong muốn cho AI, nhưng Terraform v1 chỉ dùng ECS rolling deployment circuit breaker.

---

## 5. Environment separation

| Env | Purpose | AWS Account Scope | Auto-deploy trigger |
|---|---|---|---|
| Sandbox | Kỹ sư chạy thử nghiệm IaC và ứng dụng độc lập | Sandbox Account / Dev environment | Chạy thủ công hoặc push lên feature branch |
| Staging | Tích hợp E2E giữa hạ tầng CDO và AI Engine | Shared Capstone Account (Staging resource) | Tự động chạy khi merge PR vào nhánh `develop` |
| Prod | Môi trường demo final trước Panel đánh giá | Shared Capstone Account (Production resource) | Tự động chạy khi merge PR vào nhánh `main` |

*Lưu ý: Môi trường `Prod` được bảo vệ bằng tính năng **Required Reviewers** trên GitHub. Khi deploy lên Prod, hệ thống sẽ tạm dừng chờ Tech Lead (Hoàng và An) duyệt thủ công (Manual Approval Gate).*

---

## 6. Secrets in pipeline

- **Không dùng static keys**: Pipeline sử dụng cơ chế OIDC (OpenID Connect) thông qua AWS Security Token Service (STS) để Assume Role tạm thời từ GitHub Actions sang AWS. Không lưu trữ AWS Access Key/Secret Key cố định trên GitHub.
  - *Permissions Block (Đặc quyền tối thiểu)*: Khóa toàn bộ quyền mặc định ở cấp workflow, chỉ mở quyền tạo token ngắn hạn cho job cần thiết:
    ```yaml
    permissions: read-all
    jobs:
      deploy:
        permissions:
          id-token: write
          contents: read
    ```
- **Tự động quét bí mật**: Tích hợp bước chạy **Gitleaks** trong CI workflow trên các nhánh PR. Nếu phát hiện chuỗi ký tự khớp với pattern khóa bảo mật (API keys, passwords, credentials), workflow sẽ tự động thất bại và chặn không cho merge.

---

## 7. Tenant onboarding deployment

Mô hình tự động hóa onboarding cho khách hàng mới (tenant):
1. Client gửi yêu cầu khởi tạo tenant tới Telemetry API (`POST /v1/tenants`).
2. API thực thi cập nhật cấu hình động trên cơ sở dữ liệu DynamoDB (lưu metadata của tenant và mức giới hạn quota).
3. Hệ thống tạo các phân vùng thư mục riêng biệt trên S3 (`s3://telemetry-log-bucket/tenant_id=tnt-xxx/`).
4. Quá trình onboarding diễn ra hoàn toàn tự động dưới 1 phút mà không cần chạy lại IaC/Terraform.

---

## 8. Observability stack

| Component | Tool | Description |
|---|---|---|
| Metrics & Logs | CloudWatch Logs/Metrics | Nhận application logs và custom metrics từ Telemetry API, Prediction Worker và AI Engine. |
| Metric Evidence | Amazon Managed Service for Prometheus (AMP) | Source of truth cho telemetry window 120 phút; Prediction Worker query bằng PromQL `query_range` theo tenant/service/metric trước khi gọi AI. |
| Decision Evidence | DynamoDB Audit Table | Lưu prediction/fallback decision theo tenant/service/time primary key, tra cứu prediction GSI và timestamp. |
| Dashboards | CloudWatch Dashboard | Trực quan hóa API latency, ECS CPU/memory, SQS backlog, AI p99, fallback rate và audit status. |
| Alerts | CloudWatch Alarms + SNS | Bắn email/webhook khi có high-risk decision, DLQ depth > 0, AI p99 > 500ms, audit write failure hoặc budget threshold. |
| Evidence/Failure Buffer | Amazon S3 | Lưu evidence export và raw telemetry failure buffer ngắn hạn; không dùng S3/Athena làm prediction hot path. |


---

## 9. Alternatives considered (Các giải pháp thay thế đã cân nhắc)

- **Argo CD & Kubernetes (EKS)**:
  - *Lý do không chọn:* Tốn chi phí duy trì cố định tối thiểu $73/tháng cho EKS Control Plane (vượt quá 35% ngân sách $200). Độ phức tạp vận hành cao và rủi ro trễ tiến độ lớn trong thời gian build 6 ngày.
  - *Giải pháp tối ưu:* Chọn cụm serverless **ECS Fargate** kết hợp **GitHub Actions + ECS deployment circuit breaker** giúp tối ưu chi phí cố định về $0 và rollback tự động đủ cho Terraform v1. Canary/blue-green là post-MVP.

---

## 10. Open questions

- [x] Q1: Cơ chế rotate mật khẩu tự động của database trong Secrets Manager có cần đồng bộ tức thời với ứng dụng ECS Fargate để tránh gián đoạn kết nối không? - *Resolved: AMP không dùng InfluxDB database token; AMP write/query dùng IAM SigV4. Secrets còn lại là endpoint/config/webhook/tenant token và rotate theo runbook riêng.*
- [x] Q2: Có cần cấu hình CloudWatch Logs Subscription Filter/Kinesis Firehose/Athena cho MVP không? - *Resolved: Không dùng trong MVP; CloudWatch + AMP + DynamoDB là primary observability/evidence path.*
- [x] Q3: Multi-region DR cho AI Engine không nằm trong Terraform v1/capstone MVP. MVP chỉ chạy single-region `us-east-1`; backups/versioning/lifecycle là đủ cho scope hiện tại.
- [x] Q4: Không đặt daily AI cost cap riêng trong Terraform v1. Dùng AWS Budget monthly `$200` với SNS email cảnh báo 50/80/100%; nếu cần emergency scale-down AI, Worker phải fallback static threshold và vẫn ghi audit.

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Hạ tầng trong thiết kế này được triển khai theo các sync waves của CI/CD.
- [`03_security_design.md`](03_security_design.md) - Cụ thể hóa cơ chế bảo mật OIDC và KMS khóa dữ liệu.
- [`08_adrs.md`](08_adrs.md) - Lưu vết lý do chọn SLO Early-Warning Control Plane, ECS Fargate, AMP, DynamoDB audit, EventBridge/SQS orchestration và AI Engine on ECS.
