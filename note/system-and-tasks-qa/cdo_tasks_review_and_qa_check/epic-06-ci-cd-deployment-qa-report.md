# Báo cáo QA EPIC-06: CI/CD & Deployment

Ngày review: 2026-06-29

Phạm vi QA:

- GitHub Actions deploy workflow
- Docker build matrix
- ECR push
- Gitleaks/Trivy/security scan
- Terraform plan/apply behavior
- backend/state/env handling
- manual approval gate
- OIDC trust policy
- post-deploy smoke test
- AI canary/rolling deployment claim

Không chạy deploy. Không chạy AWS-mutating command.

---

## 1. Kết luận tổng quan

Status: `PARTIAL`.

EPIC-06 đã có workflow skeleton khá đầy đủ: lint job, security scan, build matrix, ECR push, Terraform plan/apply. Tuy nhiên chưa đạt QA pass vì PR plan có thể bị skip, Terraform apply dùng `-lock=false` và `-auto-approve`, backend key đang hardcode sandbox, OIDC trust rộng hơn docs, smoke test chỉ `echo`, và CodeDeploy canary chưa được implement.

---

## 2. Phạm vi Jira

| Jira ID | Title | Status |
|---|---|---:|
| CPOA-78 | EPIC-06 - CI/CD & Deployment | `PARTIAL` |
| CPOA-79 | GitHub Actions base CI | `PARTIAL` |
| CPOA-80 | Docker build matrix | `PASS` |
| CPOA-81 | Push images to ECR | `PASS` |
| CPOA-82 | Trivy + Gitleaks | `PARTIAL` |
| CPOA-83 | Terraform plan on PR | `FAIL` |
| CPOA-84 | Manual approval gate | `FAIL` |
| CPOA-85 | ECS rolling deploy Telemetry/Worker | `PARTIAL` |
| CPOA-86 | CodeDeploy canary for AI Engine | `NOT IMPLEMENTED` |
| CPOA-87 | Post-deploy smoke test | `FAIL` |

Evidence: `docs/jira_task_collection_full.md:150`.

---

## 3. Kỳ vọng và thực tế

Kỳ vọng:

```text
PR -> tests/scans -> Terraform plan
merge/push -> build images -> push ECR -> reviewed apply/manual gate
post-deploy -> real smoke checks
AI Engine -> canary or documented rolling fallback
```

Thực tế:

```text
push/PR triggers exist
build matrix exists
ECR push exists
Terraform plan/apply exists
PR plan likely skipped by job dependency
apply uses -lock=false and -auto-approve
smoke is echo only
OIDC trust broad
AI canary not implemented
```

---

## 4. Evidence đã kiểm tra

Evidence đạt PASS/PARTIAL:

- Workflow triggers: `.github/workflows/deploy.yml:3-10`
- lint/test job: `.github/workflows/deploy.yml:21`
- security scan job: `.github/workflows/deploy.yml:65`
- build-and-push matrix: `.github/workflows/deploy.yml:79`
- Terraform deploy job: `.github/workflows/deploy.yml:136`
- OIDC provider/role: `infra/bootstrap/github_oidc.tf:27`, `infra/bootstrap/github_oidc.tf:73`
- ECR repos: `infra/terraform/modules/compute/main.tf:245`

Evidence fail/gap:

- build job only on push: `.github/workflows/deploy.yml:79-87`
- terraform deploy depends on build: `.github/workflows/deploy.yml:136-140`
- apply auto approve / no lock: `.github/workflows/deploy.yml:162-174`
- smoke test placeholder: `.github/workflows/deploy.yml:176-182`
- test deps only `pytest`: `.github/workflows/deploy.yml:56-62`
- backend hardcodes sandbox key: `infra/terraform/backend.tf:21-28`
- allowed OIDC subjects local unused: `infra/bootstrap/github_oidc.tf:11-23`
- broad trust condition: `infra/bootstrap/github_oidc.tf:45-68`
- deployment design requires gates/smoke: `docs/04_deployment_design.md:76-91`
- docs admit CodeDeploy canary not in Terraform v1 / rolling fallback: `docs/04_deployment_design.md:153`, `docs/04_deployment_design.md:174-190`

---

## 5. Findings theo severity

### P0: Terraform PR plan có thể bị skip

`terraform-deploy` phụ thuộc `build-and-push`, trong khi `build-and-push` chỉ chạy khi push. Với PR trigger, Terraform plan có thể bị block hoặc skip.

Evidence:

- `.github/workflows/deploy.yml:3-10`
- `.github/workflows/deploy.yml:79-87`
- `.github/workflows/deploy.yml:136-140`
- `docs/04_deployment_design.md:40-41`

Hướng xử lý:

- Tách PR plan job khỏi push build/apply path.
- Với PR, dùng placeholder/no-image hoặc current deployed image vars, nhưng vẫn phải chạy `terraform plan`.

### P0: Terraform apply chưa an toàn

Workflow dùng `-lock=false` và `-auto-approve`, không khớp kỳ vọng về state safety và manual gate.

Evidence:

- `.github/workflows/deploy.yml:162-174`
- `docs/04_deployment_design.md:76-91`

Hướng xử lý:

- Bỏ `-lock=false`, trừ khi có emergency path được document rõ.
- Dùng GitHub Environments required reviewers trước apply.
- Lưu plan artifact và apply đúng plan đó.

### P0: backend/env state separation có rủi ro

Backend key đang hardcode sandbox trong khi workflow map branch sang staging/prod. Chưa thấy env-specific backend override.

Evidence:

- `infra/terraform/backend.tf:21-28`
- `.github/workflows/deploy.yml:136-159`
- `docs/04_deployment_design.md:43-57`

Hướng xử lý:

- Dùng `terraform init -backend-config="key=tf4-cdo04/${ENV}/terraform.tfstate"`.
- Ghi rõ state key theo từng env trong workflow.

### P0: OIDC trust policy quá rộng

Local allowed-subject computation tồn tại, nhưng trust policy condition vẫn cho phép repo wildcard.

Evidence:

- `infra/bootstrap/github_oidc.tf:11-23`
- `infra/bootstrap/github_oidc.tf:45-68`
- `docs/04_deployment_design.md:37-40`

Hướng xử lý:

- Trust đúng các branch/environment subjects cần dùng cho `main`, `develop` và smoke paths đã duyệt.

### P1: smoke test tạo false green

Post-deploy smoke step chỉ echo success.

Evidence: `.github/workflows/deploy.yml:176-182`.

Hướng xử lý:

- Query Terraform output ALB DNS.
- `curl /health` và `/v1/ingest`.
- Check ECS service stable và DLQ không tăng.

### P1: CI test install chưa đủ

Workflow chỉ install `pytest`, trong khi service tests cần FastAPI/Pydantic/httpx và các dependency khác.

Evidence:

- `.github/workflows/deploy.yml:56-62`
- `src/telemetry_api/requirements.txt`
- `src/ai_engine/requirements.txt`

Hướng xử lý:

- Install requirements của từng service trước khi chạy tests, hoặc tách test jobs theo service với đúng working dir.

### P2: CodeDeploy canary chưa implement

Docs/Jira có nhắc AI canary, còn Terraform hiện dùng ECS rolling. Docs cũng có đoạn thừa nhận downgrade.

Evidence:

- `docs/04_deployment_design.md:153`
- `docs/04_deployment_design.md:174-190`

Hướng xử lý:

- Implement CodeDeploy canary, hoặc chỉnh Jira acceptance thành ECS rolling cho scope capstone.

---

## 6. Phụ thuộc liên epic

- EPIC-02 image/runtime correctness phụ thuộc build/push/deploy real images.
- EPIC-03/04 không thể được tin cậy nếu chưa có real smoke/E2E sau deploy.
- EPIC-07 test evidence phụ thuộc CI chạy tests thật.
- EPIC-08 cost breaker không được làm CI smoke scale services xuống ngoài ý muốn.

---

## 7. Hạng mục chấp nhận chưa hoàn tất

| Item | Status | Note |
|---|---:|---|
| CodeDeploy canary | `PARTIAL` | Docs hiện nói Terraform v1 dùng ECS rolling; Jira cần chỉnh scope hoặc phải implement. |

---

## 8. Việc tiếp theo cho Jira

1. Tách PR plan job khỏi push deploy job.
2. Bỏ `-lock=false`; dùng locking và saved plan artifact.
3. Thêm GitHub Environment approval trước apply.
4. Thêm env-specific backend key config.
5. Siết OIDC trust condition.
6. Thay smoke echo bằng HTTP/ECS/SQS checks thật.
7. Install service requirements trong CI test jobs.
8. Chốt CodeDeploy canary hay ECS rolling acceptance.

---

## 9. Read-only verification commands

```bash
rg -n "configure-aws-credentials|gitleaks|trivy|terraform plan|terraform apply|lock=false|auto-approve|environment:|workflow_dispatch|smoke|needs:" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/.github/workflows /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra/bootstrap /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra/terraform
```

---

## 10. Kết luận cuối

EPIC-06 chưa pass. Pipeline đã có khung, nhưng các gate quan trọng còn chưa an toàn hoặc chưa chạy thật. Cần fix backend/env/locking/OIDC/smoke trước khi dùng CI làm deploy source-of-truth.
