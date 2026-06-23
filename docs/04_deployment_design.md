# Deployment & CI/CD Design - Task force 4 · CDO 04

<!-- Doc owner: Nguyễn Văn Huy Hoàng (Hoàng)
     Status: Draft (W11 T4)
     Word target: 1200-2000 từ -->

## 1. IaC strategy

### 1.1 Tool choice

- **IaC tool**: **Terraform (v1.5+)**
  - **Lý do lựa chọn**: Terraform cung cấp cơ chế quản lý trạng thái hạ tầng mạnh mẽ, thư viện tài nguyên phong phú trên AWS, hỗ trợ viết code dạng khai báo (declarative) giúp dễ dàng theo dõi và tái sử dụng qua các module. Việc phân tách môi trường staging/production được thực hiện mượt mà thông qua Terraform Workspaces hoặc môi trường riêng biệt.
- **State backend**: **Amazon S3** (để lưu trữ state file từ xa) phối hợp với **Amazon DynamoDB** (để thực hiện State Lock, tránh xung đột ghi đè khi nhiều kỹ sư cùng chạy terraform apply).
- **Modular structure**: Chia nhỏ hạ tầng thành các module độc lập (networking, compute, data, tenant-provision, observability) để dễ dàng cô lập lỗi và quản lý.

### 1.2 Module structure

```
infra/
├── modules/
│   ├── networking/        # VPC, subnets, route tables, Security Groups, Internet & NAT Gateway
│   ├── compute/           # Cụm ECS Cluster, ECS Fargate Service (Telemetry API & Worker)
│   ├── data/              # DynamoDB (Audit log), SQS queues (và DLQ), RDS Aurora MySQL
│   ├── tenant-provision/  # Script/Step Functions tự động phân vùng S3 & DynamoDB cho tenant mới
│   └── observability/     # CloudWatch Log Groups, Subscription Filters, Kinesis Firehose, S3 & Athena
├── environments/
│   ├── sandbox/           # Môi trường chạy thử nghiệm của dev
│   ├── staging/           # Môi trường tích hợp E2E của Task Force 4
│   └── prod/              # Môi trường chạy demo final
└── README.md
```

### 1.3 State management

- **Remote state**: Lưu trữ riêng biệt trong các S3 buckets tương ứng với từng môi trường (ví dụ `tf4-cdo04-staging-tfstate`).
- **State lock**: Sử dụng bảng DynamoDB `tf4-cdo04-tflocks`.
- **Pipeline integration**: Thực hiện chạy `terraform plan` tự động khi mở Pull Request (PR) và chỉ thực hiện `terraform apply` tự động sau khi PR được merge vào nhánh chính tương ứng.

---

## 2. CI/CD pipeline

### 2.1 Pipeline stages

```
PR opened ──► Build ──► Test ──► Scan ──► Plan ──► Review ──► Merge ──► Apply ──► Smoke test
```

| Stage | Tool | What it does | Quality gate |
|---|---|---|---|
| Build | GitHub Actions | Compile mã nguồn, build Docker image cho Telemetry API & Worker | Build thành công không có lỗi cú pháp |
| Test | Pytest | Chạy unit test & integration test cho worker và API | Coverage ≥ 80% |
| Scan | Trivy + Gitleaks | Quét lỗ hổng bảo mật image Docker và quét secret leak trong code | 0 lỗi CRITICAL, 0 leak detected |
| Plan | Terraform CLI | Chạy `terraform plan` để kiểm tra thay đổi hạ tầng trước khi merge | Plan review được phê duyệt |
| Apply | Terraform CLI | Tự động chạy `terraform apply` để cập nhật hạ tầng sau khi merge | Apply thành công 100% tài nguyên |
| Smoke | Custom Python script | Gọi thử endpoint kiểm tra sức khỏe hệ thống (healthcheck) | Trả về HTTP 200 OK |

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
        service: [payment-gateway, ledger-service, kyc-worker]
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
| 2 | Observability Core (CloudWatch Logs, S3, Firehose) | Hạ tầng giám sát sẵn sàng nhận log |
| 3 | Compute Layer (ECS Cluster, Fargate Task Definitions) | Môi trường tính toán chứa container |
| 4 | DNS & Load Balancing (ALB, Route53, Athena) | Cầu nối định tuyến và truy vấn |

---

## 4. Deployment strategy

### 4.1 Strategy

- **Canary Deployment**: Triển khai ứng dụng theo cơ chế Canary trên ECS Fargate thông qua AWS CodeDeploy:
  - Phase 1: Chuyển **10%** traffic sang container mới, duy trì theo dõi trong 5 phút.
  - Phase 2: Chuyển **50%** traffic, theo dõi trong 5 phút tiếp theo.
  - Phase 3: Chuyển **100%** traffic để hoàn tất quá trình cập nhật.
- **Abort & Rollback Criteria**:
  - Tỷ lệ lỗi HTTP 5xx của Telemetry API vượt quá **1%** trong quá trình deploy.
  - Độ trễ p99 của API vượt quá **800ms**.
  - Có cảnh báo lỗi từ CloudWatch Metric Alarm gửi về SNS.

### 4.2 Rollback method

- **Tự động**: AWS CodeDeploy tự động ngắt luồng chuyển đổi traffic và chuyển toàn bộ 100% traffic ngược lại cụm container cũ ngay lập tức nếu vi phạm bất kỳ tiêu chí abort nào ở trên.
- **Thủ công**: Điều hành viên có thể bấm "Rollback" trên AWS Console hoặc trigger qua GitHub Actions để ép buộc rollback ngay lập tức.
- **Target RTO (Recovery Time Objective)**: $< 60$ giây.

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
| Metrics & Logs | CloudWatch Logs | Nhận log telemetry JSON thô trực tiếp từ các service demo. |
| Ingestion & Buffer | Kinesis Data Firehose | Stream log thời gian thực từ CloudWatch logs về S3, thời gian buffer 60 giây để đảm bảo độ trễ thấp. |
| Storage | Amazon S3 | Kho dữ liệu trung tâm (Data Lakehouse) được phân vùng theo giờ để lưu trữ log telemetry lâu dài. |
| Query Engine | Amazon Athena | Trích xuất dữ liệu metric chuỗi thời gian 2 tiếng gần nhất từ S3 cho Prediction Worker truy vấn. |
| Dashboards | CloudWatch Dashboard | Trực quan hóa dữ liệu sinh hiệu hệ thống cho SRE (Evidence Visualization). |
| Alerts | Amazon SNS | Bắn email/webhook cảnh báo khi có nguy cơ SLO breach hoặc khi AI sập và kích hoạt Fallback. |

---

## 9. Alternatives considered (Các giải pháp thay thế đã cân nhắc)

- **Argo CD & Kubernetes (EKS)**:
  - *Lý do không chọn:* Tốn chi phí duy trì cố định tối thiểu $73/tháng cho EKS Control Plane (vượt quá 35% ngân sách $200). Độ phức tạp vận hành cao và rủi ro trễ tiến độ lớn trong thời gian build 6 ngày.
  - *Giải pháp tối ưu:* Chọn cụm serverless **ECS Fargate** kết hợp **GitHub Actions + AWS CodeDeploy** giúp tối ưu chi phí cố định về $0 và đạt tính năng Canary/Rollback tự động nhanh chóng.

---

## 10. Open questions

- [ ] Q1: Cơ chế rotate mật khẩu tự động của database trong Secrets Manager có cần đồng bộ tức thời với ứng dụng ECS Fargate để tránh gián đoạn kết nối không?
- [ ] Q2: Có cần cấu hình CloudWatch Logs Subscription Filter giới hạn chặt chẽ hơn để giảm chi phí truyền dữ liệu qua Kinesis Firehose trong budget $200 không?
- [ ] Q3: Liệu việc tích hợp Multi-region cho Disaster Recovery của AI Engine (nhắc đến trong Deployment Contract) có nằm trong phạm vi đánh giá của Capstone không hay chỉ chạy Single-region ap-southeast-1?
- [ ] Q4: Mức Cost Cap (hạn mức chi phí) tối đa mỗi ngày của AI Engine là bao nhiêu để CDO thiết lập Circuit Breaker tự động ngắt tải?

## Related documents

- [`02_infra_design.md`](02_infra_design.md) - Hạ tầng trong thiết kế này được triển khai theo các sync waves của CI/CD.
- [`03_security_design.md`](03_security_design.md) - Cụ thể hóa cơ chế bảo mật OIDC và KMS khóa dữ liệu.
- [`08_adrs.md`](08_adrs.md) - Lưu vết lý do chọn giải pháp Serverless Lakehouse (ADR-002).
