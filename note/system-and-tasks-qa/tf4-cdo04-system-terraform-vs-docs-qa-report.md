# Báo cáo QA hệ thống TF4 CDO-04: Terraform vs docs

Ngày review: 2026-06-29

Phạm vi QA:

- `tf4-cdo04-repo/infra`
- `tf4-cdo04-repo/docs`
- `tf4-cdo04-repo/contracts`
- `.github/workflows`
- app code trong `src/`
- test/smoke code trong `tests/`

## 1. Kết luận tổng quan

Hệ thống hiện ở trạng thái `PARTIAL`.

Terraform đã dựng được phần lớn control plane: VPC, ECS Fargate, Service Connect, SQS/DLQ, DynamoDB audit, AMP workspace, S3 evidence, CloudWatch alarms/dashboard, Budget, ECR, CI build/push/deploy skeleton.

Chưa thể gọi là ready vì docs/contracts và implementation còn lệch ở các điểm P0:

1. Public ingress đang là `HTTP :80`, trong khi security docs yêu cầu `HTTPS :443` / TLS.
2. ALB ingress default còn mở public rộng.
3. CI/CD có rủi ro state/backend/env và vẫn dùng `-lock=false`.
4. GitHub OIDC trust policy rộng hơn docs yêu cầu.
5. AI ECS task trong Terraform còn chạy placeholder inline server, chưa chạy real app image đúng contract.
6. Worker -> AI auth model lệch: Worker ký `execute-api` nhưng gọi Service Connect URL; AI app không enforce auth.
7. Telemetry AMP path chưa phải Prometheus `remote_write` thật.
8. Smoke/E2E/testing còn nhiều placeholder, chưa chứng minh được luồng thực tế.

Kết luận: infra/app đủ khung cho demo nội bộ, nhưng chưa đạt QA sign-off cho production-like acceptance.

---

## 2. Thứ tự source-of-truth

Khi có conflict, ưu tiên theo thứ tự:

1. Jira task scope: `docs/jira_task_collection_full.md`
2. Contracts: `tf4-cdo04-repo/contracts/*.md`
3. Design docs: `tf4-cdo04-repo/docs/*.md`
4. Terraform/workflows hiện tại: `infra/**`, `.github/workflows/**`
5. App/tests hiện tại: `src/**`, `tests/**`

Quy tắc review: nếu docs nói đã có nhưng code/workflow chưa chạy thật, status là `PARTIAL` hoặc `FAIL`, không tính là pass.

---

## 3. Scorecard hệ thống

| Domain | Status | QA note |
|---|---:|---|
| Networking / security edge | `PARTIAL` | VPC/private ECS đã có, nhưng ALB đang dùng HTTP và default ingress còn rộng. |
| ECS / Service Connect | `PARTIAL` | ECS services và Service Connect đã có, nhưng AI task còn placeholder. |
| Data layer | `PARTIAL` | SQS/DLQ/DynamoDB/S3/AMP đã có, Scheduler DLQ chưa wired. |
| Telemetry ingestion | `PARTIAL` | `/v1/ingest` và validation đã có, AMP `remote_write` thật chưa có. |
| Prediction path | `PARTIAL` | Worker có SQS/AMP/AI/audit flow, nhưng auth model và runtime proof chưa đủ. |
| CI/CD | `PARTIAL` | Build/push/plan/apply skeleton đã có, nhưng PR plan/manual gate/smoke/state locking còn yếu. |
| Observability/testing | `PARTIAL` | Alarms/dashboard đã có, tests/E2E/k6 evidence chưa đủ. |
| Cost/operations | `PARTIAL` | Budget/cost breaker/runbook đã có, nhưng evidence và breaker scope chưa chốt. |

---

## 4. Ma trận lệch giữa Terraform và docs

| ID | Claim trong docs/contracts | Actual implementation | Status | Impact | Evidence | Epic owner |
|---|---|---|---:|---|---|---|
| SYS-01 | Public ingest phải dùng HTTPS/TLS 1.2+ trên 443; HTTP disabled/redirect | ALB listener chỉ port 80 HTTP | `FAIL` | Public security posture không khớp docs | `docs/03_security_design.md:124-145`, `docs/02_infra_design.md:28-29`, `infra/terraform/modules/compute/alb.tf:1-76`, `infra/terraform/modules/networking/security_groups.tf:22-30` | EPIC-02 / EPIC-06 |
| SYS-02 | ALB ingress không được có unsafe public default | `alb_ingress_cidr` default/usage cho public HTTP ingress | `FAIL` | Dễ apply nhầm open ingress | `infra/terraform/modules/networking/variables.tf:39-43`, `infra/terraform/modules/networking/security_groups.tf:22-30`, `docs/03_security_design.md:124-131` | EPIC-02 |
| SYS-03 | Backend state key tách theo env, locking an toàn | backend hardcode sandbox key; workflow dùng `-lock=false` | `FAIL` | Rủi ro state drift/race giữa env | `infra/terraform/backend.tf:21-28`, `.github/workflows/deploy.yml:136-174`, `docs/04_deployment_design.md:43-57` | EPIC-06 |
| SYS-04 | PR phải chạy Terraform plan | `terraform-deploy` phụ thuộc `build-and-push`, job build chỉ chạy push | `PARTIAL` | Infra PR có thể thiếu plan gate | `.github/workflows/deploy.yml:3-10`, `.github/workflows/deploy.yml:79-87`, `.github/workflows/deploy.yml:136-140`, `docs/04_deployment_design.md:40-41` | EPIC-06 |
| SYS-05 | Manual approval + post-deploy smoke thật | Workflow có apply auto-approve; smoke chỉ `echo` | `FAIL` | False-green deploy | `.github/workflows/deploy.yml:162-183`, `docs/04_deployment_design.md:76-91` | EPIC-06 / EPIC-07 |
| SYS-06 | OIDC trust scoped repo/branch/environment | local allowed subjects tồn tại nhưng trust policy cho repo wildcard | `FAIL` | Assume-role surface rộng hơn cần thiết | `infra/bootstrap/github_oidc.tf:11-23`, `infra/bootstrap/github_oidc.tf:45-68`, `docs/04_deployment_design.md:37-40` | EPIC-06 |
| SYS-07 | Runtime IAM least privilege, không wildcard data-plane | Compute variables có fallback `*`, root chưa pass đủ exact ARNs | `FAIL` | Task role bị cấp quyền rộng | `infra/terraform/main.tf:46-106`, `infra/terraform/modules/compute/variables.tf:162-194`, `infra/terraform/modules/compute/prediction_worker.tf:78-124`, `docs/03_security_design.md:197-214` | EPIC-02 / EPIC-04 |
| SYS-08 | AI Engine deploy real service contract | Terraform AI task chạy inline placeholder Python server | `FAIL` | ECS có thể healthy nhưng không chứng minh real AI app | `infra/terraform/modules/compute/ai_engine.tf:157-163`, `contracts/ai-api-contract.md:36-78` | EPIC-02 / EPIC-04 |
| SYS-09 | Worker -> AI IAM SigV4 enforced | Worker ký `execute-api`, gọi Service Connect URL; AI app không enforce auth | `FAIL` | Auth contract không có enforcing component | `src/prediction_worker/app.py:377`, `infra/terraform/modules/compute/prediction_worker.tf:209`, `src/ai_engine/app/main.py:89`, `contracts/ai-api-contract.md:22-31` | EPIC-04 |
| SYS-10 | Scheduler failure path có target DLQ | Scheduler DLQ TODO/resource chưa wired vào schedules | `PARTIAL` | Scheduler target failure khó recover/audit | `infra/terraform/modules/data/main.tf:82-85`, `infra/terraform/modules/data/eventbridge_scheduler.tf:71-104`, `docs/02_infra_design.md:315-321` | EPIC-04 / EPIC-07 |
| SYS-11 | Telemetry ingestion qua ADOT/Prometheus `remote_write` vào AMP | App adapter gửi JSON HTTP/stub, không Prometheus protobuf/snappy/SigV4 remote_write | `FAIL` | AMP ingestion contract chưa chứng minh | `src/telemetry_api/adapters/amp_delivery_adapter.py:43-52`, `docs/02_infra_design.md:59`, `contracts/telemetry-contract.md:20` | EPIC-03 |
| SYS-12 | k6/E2E dùng route public hiện tại `/v1/ingest` | k6 script gọi `/v1/telemetry` | `FAIL` | Load/E2E script stale, test sai path | `tests/k6/sc02_spike.js:40`, `src/telemetry_api/routes/ingest.py:26` | EPIC-07 |
| SYS-13 | Test/eval report là evidence thật | Report tự ghi draft, chưa chạy thật, còn placeholder `<X%>` | `FAIL` | Không thể dùng làm QA evidence | `docs/07_test_eval_report.md:3-5`, `docs/07_test_eval_report.md:58`, `docs/07_test_eval_report.md:273-276` | EPIC-07 |
| SYS-14 | Cost guard đầy đủ và đã test | Budget/cost breaker có, nhưng chưa có evidence test/headroom | `PARTIAL` | Cost ops chưa chứng minh hành vi | `infra/terraform/modules/observability/budgets.tf:29-163`, `src/lambda/cost_breaker.py:74`, `docs/misc/cost_guard_runbook.md:37-58` | EPIC-08 |
| SYS-15 | README/runbook vars khớp Terraform | Docs còn `enable_services`, `allowed_ingress_cidrs`, `acm_certificate_arn`, `adot_collector_image_tag`... không khớp root vars | `FAIL` | Operator dùng nhầm commands/vars | `infra/terraform/README.md:10-12`, `infra/terraform/README.md:53-65`, `infra/terraform/README.md:96-149`, `infra/terraform/variables.tf:4-77` | EPIC-06 |

---

## 5. Cross-cutting blockers

### P0: phải xử lý trước khi gọi ready

1. Public ingress security mismatch: HTTP-only ALB vs HTTPS docs.
2. CI/CD state safety: backend/env hardcode + `-lock=false` + auto-approve path.
3. OIDC trust quá rộng: branch/env allowlist không được enforce.
4. AI Engine runtime placeholder: Terraform chưa chạy real AI app đúng contract.
5. Telemetry AMP ingestion không phải `remote_write` thật: contract chưa đạt.
6. Worker -> AI auth model không nhất quán: SigV4 signing không có verifier thực tế.
7. Smoke/E2E false green: smoke chỉ `echo`, k6 stale path.

### P1: cần xử lý trước demo nghiêm túc

1. Runtime IAM wildcard fallback.
2. Scheduler target DLQ chưa wired.
3. Test/eval report chưa có measured data.
4. Cost breaker evidence/headroom chưa có.
5. Terraform README vars đã stale.
6. AI audit/backend retention wiring chưa chứng minh.

### P2: cleanup / hygiene

1. Broken `00_client_debrief.md` reference vs actual `00_client_debrief.md.md`.
2. Placeholder `tests/test_basic.py`.
3. Legacy Telemetry API route `/v1/telemetry` candidate.
4. Duplicate/stale observability alarm/dashboard wording.
5. Parent `docs/archived/*` không phải active source.

---

## 6. Stale docs / stale files / dead-code candidates

| Item | Status | Evidence | Recommendation |
|---|---:|---|---|
| `infra/terraform/README.md` | stale | mentions `enable_services`, `allowed_ingress_cidrs`, `acm_certificate_arn`, `adot_collector_image_tag`, `dashboard_url`, `sns_alert_topic_arn`; root vars không có | rewrite sau khi fix Terraform API |
| `docs/07_test_eval_report.md` | stale evidence | tự ghi draft/chưa chạy thật/placeholder | không dùng làm pass evidence cho tới khi cập nhật |
| `tests/test_basic.py` | dead/placeholder | `assert True` only | delete hoặc thay bằng real smoke/unit test |
| `tests/k6/sc02_spike.js` | stale | calls `/v1/telemetry` | update to `/v1/ingest` and current status codes |
| `src/telemetry_api/app.py` | likely stale | legacy `/v1/telemetry` while current app/tests use `/v1/ingest` | confirm Docker/runtime then delete or archive |
| `docs/00_client_debrief.md.md` | naming bug | docs reference `docs/00_client_debrief.md` | rename or fix references |
| `docs/archived/*` parent folder | archive | not active source for repo | keep as archive only, not source-of-truth |

---

## 7. Hạng mục chấp nhận chưa hoàn tất

| Item | Status | Note |
|---|---:|---|
| HTTPS/ACM if product owner intentionally deferred | `PARTIAL` | Nếu HTTP-only là quyết định mới, docs/security/contracts phải cập nhật rõ. Hiện docs vẫn nói HTTPS. |
| CodeDeploy canary for AI | `PARTIAL` | Docs có đoạn downgrade sang ECS rolling; Jira cần clarify acceptance. |

---

## 8. Thứ tự fix đề xuất

1. Chốt public edge: implement HTTPS/ACM + redirect, hoặc cập nhật docs/contracts nếu sandbox intentionally HTTP.
2. Fix CI/CD safety: env-specific backend config, remove `-lock=false`, real PR plan, manual approval, real smoke.
3. Tighten GitHub OIDC trust policy theo branch/environment subjects.
4. Replace AI ECS placeholder command bằng real image/app command.
5. Resolve Worker -> AI auth model: add real enforcing layer hoặc update contract to Service Connect-only trust.
6. Implement real AMP ingestion path: ADOT/Prometheus `remote_write` hoặc app SigV4 remote_write đúng format.
7. Wire Scheduler target DLQ and exact IAM ARNs.
8. Fix tests/E2E: k6 paths, SC-01/03/04, multi-tenant isolation, measured report.
9. Update stale README/docs and remove placeholder/dead files.

---

## 9. Read-only verification commands

```bash
git -C /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo status --short --branch
```

```bash
rg -n "HTTPS|443|HTTP|CodeDeploy|canary|manual approval|OIDC|use_lockfile|-lock=false|remote_write|/v1/ingest|/v1/telemetry|SigV4|Budget|cost breaker|TTL|fallback" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo
```

```bash
rg -n "configure-aws-credentials|gitleaks|trivy|terraform plan|terraform apply|lock=false|environment:|workflow_dispatch|smoke" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/.github/workflows /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra
```

```bash
rg -n "/v1/telemetry|/v1/ingest|SC-0[1-4]|<X>|DRAFT|placeholder" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/tests /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/docs
```

---

## 10. Kết luận cuối

System chưa ready để sign-off toàn bộ. Trạng thái đúng nhất: `PARTIAL`.

Infra đã có nhiều component chính, nhưng source-of-truth docs/contracts và implementation đang lệch ở security edge, CI/CD safety, AI runtime, AMP ingestion, auth model và testing evidence.

Bước tiếp theo nên là sửa các P0 theo thứ tự ở section 8, rồi chạy QA lại bằng cùng report matrix.
