# Báo cáo QA EPIC-02: ECS Services - Telemetry API, Prediction Worker, AI Engine

Ngày review: 2026-06-29

Phạm vi QA:

- ECS Cluster / Fargate services
- Telemetry API task/service
- Prediction Worker task/service
- AI Engine task/service
- ECS Service Connect
- Autoscaling
- Security Groups
- baseline S3 access cho AI

Nguồn review:

- `docs/jira_task_collection_full.md`
- `tf4-cdo04-repo/contracts/deployment-contract.md`
- `tf4-cdo04-repo/docs/02_infra_design.md`
- `tf4-cdo04-repo/docs/03_security_design.md`
- `tf4-cdo04-repo/infra/terraform/modules/compute/*.tf`
- `tf4-cdo04-repo/infra/terraform/modules/networking/security_groups.tf`
- `tf4-cdo04-repo/src/ai_engine/**`

---

## 1. Kết luận tổng quan

Status: `PARTIAL`.

Terraform đã có ECS cluster, 3 service chính, Service Connect cho Worker -> AI, autoscaling policies, IAM/task definitions, log groups và ECR repos. EPIC-02 vẫn chưa đạt sign-off vì AI Engine ECS task đang chạy placeholder inline server trong Terraform thay vì real app. Public edge/security settings cũng chưa khớp security docs, và runtime auth path Worker -> AI chưa có enforcement thật.

---

## 2. Phạm vi Jira

| Jira ID | Title | Status |
|---|---|---:|
| CPOA-45 | EPIC-02 - ECS Services: Telemetry API, Prediction Worker, AI Engine | `PARTIAL` |
| CPOA-46 | Telemetry API task definition | `PARTIAL` |
| CPOA-47 | Prediction Worker task definition | `PARTIAL` |
| CPOA-48 | AI Engine task definition | `FAIL` |
| CPOA-49 | ECS Service Connect config for AI | `PASS` |
| CPOA-50 | ECS autoscaling policy | `PASS` |
| CPOA-51 | AI Engine baseline S3 access | `PARTIAL` |

Evidence: `docs/jira_task_collection_full.md:49`.

---

## 3. Status từng subtask

| Subtask | Status | QA note |
|---|---:|---|
| Telemetry API ECS task/service | `PARTIAL` | Task/service đã có, nhưng edge vẫn HTTP-only và app image/runtime vẫn cần real deploy verification. |
| Prediction Worker ECS task/service | `PARTIAL` | Task/service đã có env/IAM, nhưng Worker -> AI auth model chưa chốt. |
| AI Engine ECS task/service | `FAIL` | Terraform task command chạy placeholder inline Python server, chưa chạy real app. |
| Service Connect `ai-engine:8080` | `PASS` | Discovery/client alias đã có cho Worker -> AI path. |
| Autoscaling | `PASS` | Autoscaling targets/policies đã có cho Telemetry API, Worker và AI. |
| AI baseline S3 access | `PARTIAL` | IAM/env wiring đã có, nhưng final baseline/evidence storage contract vẫn chưa được chứng minh đầy đủ. |

---

## 4. Kỳ vọng và thực tế

Kỳ vọng:

```text
Private ECS Fargate services
  -> Telemetry API receives public ALB traffic
  -> Prediction Worker consumes SQS
  -> Worker calls AI Engine via private Service Connect ai-engine:8080
  -> AI Engine runs real /v1/predict service
  -> autoscaling protects each service
```

Thực tế:

```text
ECS cluster + services exist
Service Connect exists
Autoscaling exists
AI Engine Terraform still starts placeholder HTTP server
Public edge is HTTP :80, not HTTPS :443
Worker -> AI auth not enforced by AI service
```

---

## 5. Evidence đã kiểm tra

Evidence đạt PASS:

- ECS cluster: `infra/terraform/modules/compute/main.tf:30`
- Service Connect namespace: `infra/terraform/modules/compute/main.tf:42`
- Telemetry API task/service: `infra/terraform/modules/compute/main.tf:111`, `infra/terraform/modules/compute/main.tf:165`
- Prediction Worker task/service: `infra/terraform/modules/compute/prediction_worker.tf:140`, `infra/terraform/modules/compute/prediction_worker.tf:251`
- AI Engine task/service: `infra/terraform/modules/compute/ai_engine.tf:137`, `infra/terraform/modules/compute/ai_engine.tf:247`
- Service Connect AI alias: `infra/terraform/modules/compute/ai_engine.tf:267`
- Autoscaling: `infra/terraform/modules/compute/autoscaling.tf:11`, `infra/terraform/modules/compute/autoscaling.tf:74`, `infra/terraform/modules/compute/autoscaling.tf:122`
- AI baseline S3 IAM: `infra/terraform/modules/compute/ai_engine.tf:47`

Evidence fail/gap:

- AI placeholder inline server: `infra/terraform/modules/compute/ai_engine.tf:157-163`
- ALB HTTP-only: `infra/terraform/modules/compute/alb.tf:1-76`
- Public HTTP ingress: `infra/terraform/modules/networking/security_groups.tf:22-30`
- HTTPS required by docs: `docs/03_security_design.md:124-145`
- Worker -> AI endpoint: `infra/terraform/modules/compute/prediction_worker.tf:201-203`
- AI app says auth edge should enforce: `src/ai_engine/app/main.py:89`

---

## 6. Findings theo severity

### P0: AI ECS task chưa chạy real app

Terraform task command đang dùng inline Python server. ECS service có thể healthy, nhưng không chứng minh được real AI Engine behavior.

Evidence: `infra/terraform/modules/compute/ai_engine.tf:157-163`.

Hướng xử lý:

- Remove placeholder command.
- Run real `src/ai_engine` app image/entrypoint.
- Keep `/health` and `POST /v1/predict` contract.

### P0: public edge không khớp security docs

Docs yêu cầu HTTPS/TLS, nhưng Terraform đang mở HTTP port 80.

Evidence:

- `docs/03_security_design.md:124-145`
- `infra/terraform/modules/compute/alb.tf:1-76`
- `infra/terraform/modules/networking/security_groups.tf:22-30`

Hướng xử lý:

- Add ACM/HTTPS listener and HTTP redirect, hoặc downgrade docs rõ ràng nếu sandbox-only HTTP là quyết định chính thức.

### P1: Worker -> AI auth enforcement chưa rõ

Worker được thiết kế ký request, nhưng AI app không enforce auth trong Service Connect path.

Evidence:

- `src/prediction_worker/app.py:377`
- `infra/terraform/modules/compute/prediction_worker.tf:209`
- `src/ai_engine/app/main.py:89`

Hướng xử lý:

- Chọn một model: API Gateway/IAM, ALB auth proxy, app-level SigV4 verification, hoặc update contract thành Service Connect trust-only.

### P1: IAM vẫn có wildcard fallback

Compute module variables cho phép `*` nếu root không truyền exact ARNs.

Evidence:

- `infra/terraform/modules/compute/variables.tf:162-194`
- `infra/terraform/modules/compute/prediction_worker.tf:78-124`

Hướng xử lý:

- Pass exact DynamoDB/SNS/SSM/Secrets/KMS resource ARNs from data module outputs.

---

## 7. Phụ thuộc liên epic

- EPIC-03 phụ thuộc Telemetry API ECS service và ALB route.
- EPIC-04 phụ thuộc Prediction Worker service, AI Engine service và Service Connect.
- EPIC-06 phụ thuộc task definitions/image tags chạy real image.
- EPIC-07 phụ thuộc services expose logs/metrics đúng cách.

---

## 8. Hạng mục chấp nhận chưa hoàn tất

| Item | Status | Note |
|---|---:|---|
| CodeDeploy canary for AI | `PARTIAL` | Jira/docs cần clarify vì current Terraform dùng ECS rolling. |

---

## 9. Việc tiếp theo cho Jira

1. Replace AI Engine placeholder command with real app entrypoint.
2. Chốt HTTPS requirement cho current environment và align Terraform/docs.
3. Tighten task role IAM resource ARNs.
4. Resolve Worker -> AI auth enforcement model.
5. Run ECS deploy smoke sau khi đổi image: task stable, target healthy, AI `/health`, Worker resolves `ai-engine:8080`.

---

## 10. Read-only verification commands

```bash
rg -n "command|service_connect_configuration|desired_count|assign_public_ip|ai-engine|8080" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra/terraform/modules/compute
```

```bash
rg -n "HTTPS|443|HTTP|alb_ingress|Service Connect|SigV4" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/docs /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra/terraform/modules
```

---

## 11. Kết luận cuối

EPIC-02 đã có nền ECS khá đầy đủ, nhưng chưa đạt QA pass. Blocker lớn nhất là AI Engine task còn placeholder và public/auth posture lệch docs.
