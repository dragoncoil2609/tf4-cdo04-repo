# EPIC-08 QA Report: Cost & Operations

Ngày review: 2026-06-29

Phạm vi QA:

- AWS Budget 50/80/100
- cost SNS + Lambda cost breaker
- cost dashboard/evidence
- AMP quota/cardinality guardrails
- Service Connect proxy cost/headroom
- retention policies
- cost guard runbook

Chỉ review tĩnh. Không gọi AWS Pricing hoặc kiểm tra trạng thái tài khoản AWS.

---

## 1. Kết luận tổng quan

Status: `PARTIAL`.

EPIC-08 có nền tảng tốt: Budget thresholds, SNS/Lambda cost breaker, dashboard, retention policies, ECR lifecycle, DynamoDB TTL, S3 lifecycle và Telemetry API cardinality guardrails. Tuy nhiên chưa pass vì chưa có measured evidence cho budget alert/cost breaker, chưa chứng minh Service Connect headroom, cost breaker scope còn phải chốt, và cost report/runbook hiện thiên về hướng dẫn hơn là verified result.

---

## 2. Jira scope

| Jira ID | Title | Status |
|---|---|---:|
| CPOA-98 | EPIC-08 - Cost & Operations | `PARTIAL` |
| CPOA-99 | AWS Budget 50/80/100 | `PASS` |
| CPOA-100 | cost dashboard/evidence | `PARTIAL` |
| CPOA-101 | AMP quota and cardinality policy | `PARTIAL` |
| CPOA-102 | Service Connect proxy cost/headroom check | `PARTIAL` |
| CPOA-103 | retention policies | `PASS` |
| CPOA-104 | cost guard runbook | `PARTIAL` |

Evidence: `docs/jira_task_collection_full.md:206`.

---

## 3. Kỳ vọng và thực tế

Kỳ vọng:

```text
Budget thresholds 50/80/100 alert
cost dashboard with useful views
cardinality/AMP guardrails enforced
Service Connect overhead/headroom validated
retention policies control storage cost
runbook tested with evidence
cost breaker behavior known and safe
```

Thực tế:

```text
Budget/cost breaker/dashboard resources exist
retention policies exist
cardinality validation exists in Telemetry API
runbook exists
measured evidence and headroom proof still missing
breaker scope needs product/security sign-off
```

---

## 4. Evidence đã kiểm tra

Evidence đạt PASS/PARTIAL:

- Budget resources/thresholds/SNS/Lambda: `infra/terraform/modules/observability/budgets.tf:29`, `infra/terraform/modules/observability/budgets.tf:61`, `infra/terraform/modules/observability/budgets.tf:163`
- Cost dashboard/billing alarm: `infra/terraform/modules/observability/cost_dashboard.tf:30`, `infra/terraform/modules/observability/cost_dashboard.tf:57`
- S3 lifecycle: `infra/terraform/modules/data/main.tf:120`
- DynamoDB TTL: `infra/terraform/modules/data/main.tf:45`
- AI audit log retention: `infra/terraform/modules/observability/main.tf:65`
- ECR lifecycle: `infra/terraform/modules/compute/main.tf:206`
- Telemetry cardinality guardrails: `src/telemetry_api/validators/labels.py:25`
- cost breaker logic: `src/lambda/cost_breaker.py:25`, `src/lambda/cost_breaker.py:74`
- runbook exists: `docs/misc/cost_guard_runbook.md:10`
- cost model docs: `docs/05_cost_analysis.md:26`, `docs/05_cost_analysis.md:44`, `docs/05_cost_analysis.md:155`

Evidence còn thiếu:

- cost breaker scales selected services only: `src/lambda/cost_breaker.py:74`
- manual runbook/evidence steps: `docs/misc/cost_guard_runbook.md:37`, `docs/misc/cost_guard_runbook.md:58`
- Service Connect headroom evidence hiện chủ yếu là docs/alarms, chưa phải measured artifact.
- `docs/07_test_eval_report.md` cho biết test evidence thực tế chưa được chạy: `docs/07_test_eval_report.md:273-276`

---

## 5. Findings theo severity

### P1 - cost breaker scope chưa chốt

Lambda hiện có vẻ scale down một số service tốn kém được chọn như `ai-engine` và `prediction-worker`, chưa chắc áp dụng cho toàn bộ nonessential platform services.

Evidence: `src/lambda/cost_breaker.py:74`.

Tác động:

- Nếu docs/contracts kỳ vọng hard stop rộng hơn, current implementation mới ở mức partial.
- Nếu intended behavior là protect core ingress nhưng dừng expensive compute, docs cần ghi rõ.

Hướng xử lý:

- Quyết định blast radius mong muốn:
  - stop only AI/Worker,
  - stop all nonessential ECS,
  - or alert-only at lower thresholds, breaker at 100%.
- Cập nhật code/docs/Jira acceptance cùng lúc.

### P1 - Budget alert/cost breaker chưa có verified evidence

Đã có Terraform/code/runbook, nhưng chưa có evidence được commit để chứng minh luồng alert 50/80/100 và Lambda path đã được test.

Evidence:

- `infra/terraform/modules/observability/budgets.tf:29-163`
- `docs/misc/cost_guard_runbook.md:37-58`

Hướng xử lý:

- Thêm test record ở non-prod: SNS test event -> Lambda action -> ECS desired count result -> rollback command.

### P1 - Service Connect headroom chưa có measured artifact

Docs có nhắc tới headroom/proxy cost và alarms đã tồn tại, nhưng chưa tìm thấy measured evidence cho CPU/memory overhead.

Tác động:

- Chưa thể xác nhận Fargate sizing/cost headroom dưới mức traffic kỳ vọng.

Hướng xử lý:

- Chạy smoke/load test và ghi lại CPU/memory trước và sau khi có Service Connect traffic.
- Bổ sung phần evidence vào cost report.

### P2 - Cost dashboard text có nguy cơ stale

Lần scan stale trước đã ghi nhận cost dashboard text còn nhắc tới các thuật ngữ kiến trúc cũ như Timestream trong khi design đã chuyển sang AMP.

Evidence: `infra/terraform/modules/observability/cost_dashboard.tf:93-99`.

Hướng xử lý:

- Cập nhật labels/text của dashboard theo kiến trúc AMP/SQS/ECS hiện tại.

### P2 - AMP/cardinality guardrail mới được chứng minh một phần

Telemetry API label guardrails đã có, nhưng evidence cho AMP quota behavior và sample rate vẫn còn thiếu.

Evidence:

- `src/telemetry_api/validators/labels.py:25`
- `docs/05_cost_analysis.md:155`

Hướng xử lý:

- Bổ sung evidence PromQL/CloudWatch cho ingestion volume và cardinality sau test run.

---

## 6. Phụ thuộc liên epic

- EPIC-03 cardinality/AMP ingestion phải chạy thật thì mới đo được AMP cost.
- EPIC-07 cần load/k6 evidence để xác nhận Service Connect headroom.
- EPIC-06 deploy workflow không được auto-trigger cost breaker ngoài ý muốn.
- EPIC-02 AI/Worker desired counts ảnh hưởng trực tiếp tới cost estimate và breaker behavior.

---

## 7. Việc tiếp theo cho Jira

1. Chốt blast radius của cost breaker và ghi rõ trong tài liệu.
2. Bổ sung evidence artifact cho luồng Budget 50/80/100 alert.
3. Bổ sung test record cho Lambda cost breaker với ECS desired counts trước và sau.
4. Bổ sung đo headroom của Service Connect sau k6/smoke run.
5. Cập nhật dashboard text nếu vẫn còn thuật ngữ kiến trúc cũ.
6. Bổ sung evidence cho AMP sample/cardinality sau khi EPIC-03 remote_write được fix.

---

## 8. Read-only verification commands

```bash
rg -n "Budget|budget|desiredCount|desired_count|retention|lifecycle|cardinality|Service Connect|Timestream|AMP|cost breaker|SNS|Lambda" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra/terraform/modules /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/src/lambda /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/src/telemetry_api /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/docs
```

---

## 9. Kết luận cuối

EPIC-08 chưa pass, nhưng nền tảng hiện khá tốt. Phần còn thiếu không nằm ở số lượng Terraform resource, mà ở verified operational evidence: budget alert test, breaker action proof, Service Connect headroom và độ chính xác của current-cost dashboard.
