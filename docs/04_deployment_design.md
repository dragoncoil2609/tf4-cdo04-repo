# Deployment & CI/CD Design - Task force 4 · CDO 04

<!-- Doc owner: Nguyễn Văn Huy Hoàng (Hoàng)
     Status: Refined (W11 T4)
     Word target: 1200-2000 từ -->

## 1. IaC strategy

### 1.1 Tool choice

- **IaC tool**: **Terraform (v1.10+)**
- **Deployment region/runtime baseline**: CDO-04 deploy tại `us-east-1` với ECS Fargate Linux/x86 cho Telemetry API, Prediction Worker và AI Engine.
  - **Lý do lựa chọn**: Terraform cung cấp cơ chế quản lý trạng thái hạ tầng mạnh mẽ, thư viện tài nguyên phong phú trên AWS, hỗ trợ viết code dạng khai báo (declarative) giúp dễ dàng theo dõi và tái sử dụng qua các module.
- **State backend**: **Amazon S3** remote backend với native lockfile (`use_lockfile = true`). Baseline mới **không tạo DynamoDB lock table** vì Terraform S3 native locking đã đủ cho workflow này và giữ bootstrap đơn giản.
- **GitHub OIDC bootstrap**: `infra/bootstrap/` phải khởi tạo **GitHub Actions OIDC provider** và Terraform deploy role/policy tối thiểu cho CI/CD assume-role. OIDC là foundation giống state backend, nên không để trong main `infra/terraform/` root để tránh chicken-and-egg khi pipeline cần quyền chạy plan/apply.
- **Modular structure**: `infra/bootstrap/` bootstrap backend + GitHub OIDC foundation; `infra/terraform/` là root module chính và gọi các module con (`networking`, `data`, `compute`, `observability`) để tránh flat Terraform khó review.

### 1.2 Module structure

```
infra/
├── bootstrap/             # One-time S3 backend bucket + KMS key + GitHub OIDC provider/deploy role; backend uses use_lockfile=true
├── terraform/             # Main Terraform root for the platform
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
- **State lock**: dùng native S3 lockfile với `use_lockfile = true`; baseline **không dùng DynamoDB lock table**.
- **GitHub OIDC foundation**: `infra/bootstrap/` cũng phải tạo IAM OIDC provider cho `token.actions.githubusercontent.com` và Terraform deploy role cho GitHub Actions. Trust policy phải giới hạn theo đúng GitHub org/repo/branch hoặc environment; role này là role pipeline dùng để chạy `terraform plan/apply` cho main root.
- **Pipeline integration**: Thực hiện chạy `terraform plan` tự động khi mở Pull Request (PR) và chỉ thực hiện `terraform apply` sau khi PR được merge vào nhánh chính tương ứng.

---

## 2. CI/CD pipeline

### 2.1 Pipeline stages

```
PR opened ──► Doc Check ──► Lint & Validate ──► Build ──► Test ──► Scan ──► Plan ──► Review ──► Merge ──► Manual Approval ──► Apply ──► Smoke test
```

| Stage | Tool | What it does | Quality gate |
|---|---|---|---|
| Doc Check | Markdown-lint / Script | Kiểm tra tính hoàn thiện và định dạng của tài liệu Markdown | Không có lỗi cú pháp Markdown hoặc link hỏng |
| Lint & Validate | Terraform CLI | Chạy `terraform fmt -check` và `terraform validate` kiểm tra cú pháp IaC | Cú pháp đúng chuẩn declarative và định dạng đồng nhất |
| Build | GitHub Actions | Compile mã nguồn, build Docker image cho Telemetry API, Prediction Worker và AI Engine | Build thành công không có lỗi cú pháp |
| Test | Pytest | Chạy unit test & integration test cho worker và API | Coverage ≥ 80% |
| Scan | Gitleaks + Trivy | Quét secret leak trong mã nguồn và quét lỗ hổng bảo mật image Docker | 0 leak detected, 0 lỗi CRITICAL |
| Plan | Terraform CLI | Chạy `terraform plan` để kiểm tra thay đổi hạ tầng trước khi merge | Plan review được phê duyệt và hiển thị trên PR |
| Review & Merge | GitHub PR | Rà soát chéo code và merge nhánh dựa trên Peer Review Matrix | Ít nhất 1 approval từ Reviewer được chỉ định |
| Manual Approval | GitHub Environments | Tạm dừng chờ Tech Lead phê duyệt trước khi chạy deploy | Trạng thái: Approved (áp dụng bắt buộc với Production) |
| Apply | Terraform CLI | Tự động chạy `terraform apply` để cập nhật hạ tầng sau khi merge | Apply thành công 100% tài nguyên hạ tầng |
| Smoke | Custom Python script | Gọi thử endpoint kiểm tra sức khỏe hệ thống (healthcheck) sau khi deploy | Trả về HTTP 200 OK |
| AMP ingest/query validation | Custom script / PromQL | Xác nhận collector/app `remote_write` đã ghi sample vào AMP và Worker query_range trả 1-minute samples đủ 120 phút theo tenant/service/metric | Có sample mới trong AMP và PromQL trả đủ window trước khi smoke AI |

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

- **GitHub Actions & AWS CodeDeploy**: Nhóm sử dụng cơ chế GitOps tự động hóa thông qua GitHub Actions làm điều phối viên (Reconciler) phối hợp với CodeDeploy để quản lý trạng thái triển khai ứng dụng trên ECS Fargate.
- **Repo structure**: Monorepo chứa cả IaC (`infra/`), mã nguồn ứng dụng (`src/`), kịch bản test (`tests/`) và tài liệu (`docs/`).

### 3.2 Sync waves

Trong quá trình khởi tạo môi trường mới thông qua pipeline, các tài nguyên được áp dụng tuần tự theo các đợt (sync waves) để tránh lỗi phụ thuộc:

| Wave | Components | Description |
|---|---|---|
| 0 | Networking (VPC, Subnets, SG) | Hạ tầng mạng cơ bản |
| 1 | Database & Message Queue (DynamoDB, SQS) | Nơi lưu trữ và truyền tin |
| 2 | Observability Core (CloudWatch Logs/Metrics, Dashboard, SNS) | Hạ tầng giám sát và alert sẵn sàng nhận log/metric |
| 3 | Compute Layer (ECS Cluster, Fargate Task Definitions cho Telemetry API, Worker, AI Engine) | Môi trường tính toán chứa container |
| 4 | Ingress + private service routing | Public `/v1/ingest` đi qua public ALB; Worker gọi AI qua ECS Service Connect service name trong private subnets. Route 53/private DNS không nằm trong baseline MVP. |

---

## 4. Deployment strategy

### 4.1 Strategy

- **Telemetry API và Prediction Worker**: dùng ECS rolling deployment circuit breaker để đơn giản hóa rollout cho workload nội bộ, rollback về task definition ổn định nếu health check hoặc alarm fail.
- **Riêng AI Engine**: dùng ECS Blue/Green với AWS CodeDeploy Canary theo AI Deployment Contract. ECS Service Connect xử lý private service discovery/load balancing; SigV4 enforcement phải nằm ở AI Engine middleware/sidecar trong W12 final:
  - Phase 1: Chuyển **10%** traffic sang AI task set mới, theo dõi trong 5 phút.
  - Phase 2: Chuyển **50%** traffic, theo dõi trong 5 phút tiếp theo.
  - Phase 3: Chuyển **100%** traffic để hoàn tất quá trình cập nhật.
- **AI canary abort & rollback criteria**:
  - Error rate > **1%** trong canary window.
  - AI p99 latency > **800ms** trong canary window.
  - Capacity Exhaustion false/deviation > **15%**.
- **Platform/API rollback criteria**:
  - Platform/API p99 > **800ms** trong 5 phút hoặc 5xx > **1%**.
  - Có cảnh báo lỗi từ CloudWatch Metric Alarm gửi về SNS.

### 4.2 Rollback method

- **AI Engine tự động**: AWS CodeDeploy tự động ngắt luồng chuyển đổi traffic và chuyển toàn bộ 100% traffic ngược lại previous task definition nếu vi phạm bất kỳ AI canary abort criterion nào ở trên.
- **Telemetry API / Prediction Worker tự động**: ECS deployment circuit breaker rollback task definition khi deployment mới không đạt steady state.
- **Thủ công**: Điều hành viên có thể bấm "Rollback" trên AWS Console hoặc trigger qua GitHub Actions để ép buộc rollback ngay lập tức.
- **Target RTO (Recovery Time Objective)**: $< 60$ giây cho AI rollback theo contract; platform service rollback theo ECS steady-state/circuit-breaker timing.

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
| Decision Evidence | DynamoDB Audit Table | Lưu prediction/fallback decision theo `prediction_id`, `tenant_id`, `service_id` và timestamp. |
| Dashboards | CloudWatch Dashboard | Trực quan hóa API latency, ECS CPU/memory, SQS backlog, AI p99, fallback rate và audit status. |
| Alerts | CloudWatch Alarms + SNS | Bắn email/webhook khi có high-risk decision, DLQ depth > 0, AI p99 > 500ms, audit write failure hoặc budget threshold. |
| Evidence/Failure Buffer | Amazon S3 | Lưu evidence export và raw telemetry failure buffer ngắn hạn; không dùng S3/Athena làm prediction hot path. |


---

## 9. Alternatives considered (Các giải pháp thay thế đã cân nhắc)

- **Argo CD & Kubernetes (EKS)**:
  - *Lý do không chọn:* Tốn chi phí duy trì cố định tối thiểu $73/tháng cho EKS Control Plane (vượt quá 35% ngân sách $200). Độ phức tạp vận hành cao và rủi ro trễ tiến độ lớn trong thời gian build 6 ngày.
  - *Giải pháp tối ưu:* Chọn cụm serverless **ECS Fargate** kết hợp **GitHub Actions + AWS CodeDeploy** giúp tối ưu chi phí cố định về $0 và đạt tính năng Canary/Rollback tự động nhanh chóng.

---

## 10. Open questions

- [x] Q1: Cơ chế rotate mật khẩu tự động của database trong Secrets Manager có cần đồng bộ tức thời với ứng dụng ECS Fargate để tránh gián đoạn kết nối không? - *Resolved: AMP baseline không dùng InfluxDB database token; AMP write/query dùng IAM SigV4. Secrets còn lại là endpoint/config/webhook/tenant token và rotate theo runbook riêng.*
- [x] Q2: Có cần cấu hình CloudWatch Logs Subscription Filter/Kinesis Firehose/Athena cho baseline không? - *Resolved: Không dùng trong baseline; CloudWatch + AMP + DynamoDB là primary observability/evidence path.*
- [ ] Q3: Liệu việc tích hợp Multi-region cho Disaster Recovery của AI Engine (nhắc đến trong Deployment Contract) có nằm trong phạm vi đánh giá của Capstone không hay chỉ chạy Single-region us-east-1?
- [ ] Q4: Mức Cost Cap (hạn mức chi phí) tối đa mỗi ngày của AI Engine là bao nhiêu để CDO thiết lập Circuit Breaker tự động ngắt tải?

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Hạ tầng trong thiết kế này được triển khai theo các sync waves của CI/CD.
- [`03_security_design.md`](03_security_design.md) - Cụ thể hóa cơ chế bảo mật OIDC và KMS khóa dữ liệu.
- [`08_adrs.md`](08_adrs.md) - Lưu vết lý do chọn SLO Early-Warning Control Plane, ECS Fargate, AMP, DynamoDB audit, EventBridge/SQS orchestration và AI Engine on ECS.
