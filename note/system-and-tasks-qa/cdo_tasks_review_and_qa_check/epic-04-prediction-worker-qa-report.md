# Báo cáo QA EPIC-04: Prediction Worker SQS -> AMP -> AI -> Audit

Ngày review: 2026-06-29

Phạm vi QA:

- SQS consumer loop
- AMP `query_range` 120 phút
- bucket alignment + imputation
- AI `signal_window`
- Worker -> AI call
- AI response validation
- DynamoDB audit write
- SNS high-risk alert
- idempotency
- Terraform wiring liên quan

Tuấn DynamoDB fallback policy table được xem là `ACCEPTED-INCOMPLETE`, không tính fail cho report này.

---

## 1. Kết luận tổng quan

Status: `PARTIAL`.

Prediction Worker đã tiến xa hơn bản review cũ: code có SQS loop, AMP `query_range`, alignment/imputation, `signal_window`, AI call, response validation, audit write, TTL/idempotency và SNS alert path. EPIC-04 vẫn chưa pass vì Worker -> AI auth model không khớp hạ tầng Service Connect, AI app không enforce auth, AI ECS Terraform còn chạy placeholder server, và chưa có runtime/E2E proof.

---

## 2. Phạm vi Jira

| Jira ID | Title | Status |
|---|---|---:|
| CPOA-60 | EPIC-04 - Prediction Worker: SQS -> AMP -> AI -> Audit | `PARTIAL` |
| CPOA-61 | SQS consumer loop | `PARTIAL` |
| CPOA-62 | PromQL query_range 120 phút | `PASS` |
| CPOA-63 | Bucket alignment + imputation | `PASS` |
| CPOA-64 | Build AI signal_window | `PASS` |
| CPOA-65 | Call AI /v1/predict | `PARTIAL` |
| CPOA-66 | IAM SigV4 signing Worker -> AI | `FAIL` |
| CPOA-67 | Validate AI response schema | `PASS` |
| CPOA-68 | DynamoDB audit write | `PARTIAL` |
| CPOA-69 | SNS high-risk alert | `PARTIAL` |
| CPOA-70 | Idempotency | `PASS` |

Evidence: `docs/jira_task_collection_full.md:96`.

---

## 3. Kỳ vọng và thực tế

Kỳ vọng:

```text
EventBridge Scheduler
  -> SQS Prediction Queue
  -> Prediction Worker long-poll
  -> AMP query_range 120 phút
  -> align/impute 120 buckets
  -> build signal_window
  -> call AI /v1/predict with enforced auth
  -> validate AI response
  -> write complete DynamoDB audit item with TTL/idempotency
  -> publish SNS for high-risk
  -> delete SQS message after success
```

Thực tế qua static review:

```text
Worker code implements most runtime steps
Terraform wires SQS/AMP/DynamoDB/SNS/envs
AI call path/auth remains inconsistent
AI ECS Terraform still placeholder, so E2E not proven
fallback policy table accepted incomplete
```

---

## 4. Evidence đã kiểm tra

Evidence đạt PASS/PARTIAL:

- SQS receive loop: `src/prediction_worker/app.py:480`
- delete after success: `src/prediction_worker/app.py:497`
- AMP `query_range`: `src/prediction_worker/app.py:108`, `src/prediction_worker/app.py:133`
- alignment/imputation: `src/prediction_worker/app.py:67`
- `signal_window` + context: `src/prediction_worker/app.py:322`
- AI call: `src/prediction_worker/app.py:369`
- response validation: `src/prediction_worker/app.py:394`
- audit write: `src/prediction_worker/app.py:185`
- TTL/idempotency condition: `src/prediction_worker/app.py:242`
- SNS alert path: `src/prediction_worker/app.py:256`
- DynamoDB audit table + TTL: `infra/terraform/modules/data/main.tf:12`, `infra/terraform/modules/data/main.tf:45`
- Worker IAM/env: `infra/terraform/modules/compute/prediction_worker.tf:48`, `infra/terraform/modules/compute/prediction_worker.tf:177`, `infra/terraform/modules/compute/prediction_worker.tf:201`

Evidence fail/gap:

- Worker signs AI call as `execute-api`: `src/prediction_worker/app.py:377`
- Worker AI endpoint is Service Connect URL: `infra/terraform/modules/compute/prediction_worker.tf:209`
- AI app does not enforce auth itself: `src/ai_engine/app/main.py:48`, `src/ai_engine/app/main.py:89`
- AI ECS Terraform placeholder server: `infra/terraform/modules/compute/ai_engine.tf:157-163`
- fallback table accepted incomplete: `infra/terraform/modules/data/main.tf:58-61`, `src/prediction_worker/app.py:172`

---

## 5. Findings theo severity

### P0: Worker -> AI SigV4 model không enforce được trên current path

Worker ký request như `execute-api`, nhưng hạ tầng gọi AI qua `http://ai-engine:8080/v1/predict` Service Connect. Không có API Gateway/execute-api endpoint, và AI app không verify Authorization header.

Evidence:

- `src/prediction_worker/app.py:377`
- `infra/terraform/modules/compute/prediction_worker.tf:209`
- `src/ai_engine/app/main.py:89`
- `contracts/ai-api-contract.md:22-31`

Tác động:

- CPOA-66 chưa đạt.
- Security contract Worker -> AI không có enforcement thật.

Hướng xử lý:

- Chọn một kiến trúc rõ:
  1. API Gateway private/IAM trước AI,
  2. ALB/auth proxy,
  3. app-level SigV4 verification,
  4. hoặc cập nhật contract: Service Connect trust model, không SigV4.

### P0: AI ECS task placeholder chặn E2E thật

Worker có thể gọi endpoint, nhưng Terraform AI task không chạy real AI app.

Evidence: `infra/terraform/modules/compute/ai_engine.tf:157-163`.

Hướng xử lý:

- Deploy real AI image and command.
- Ensure `POST /v1/predict` real app receives Worker payload.

### P1: SNS high-risk alert cần runtime proof

Code path đã có `sns.publish`, nhưng IAM/env cần được verify qua deploy/smoke.

Evidence:

- `src/prediction_worker/app.py:256`
- `infra/terraform/modules/compute/prediction_worker.tf:48`

Hướng xử lý:

- Thêm test case: AI returns high severity/anomaly, Worker publishes SNS, audit vẫn được ghi.

### P1: DynamoDB audit completeness cần contract pass test

Code có TTL/idempotency, nhưng cần verify item fields khớp full security/design contract sau real message.

Evidence:

- `src/prediction_worker/app.py:185`
- `src/prediction_worker/app.py:242`
- `docs/03_security_design.md` audit fields.

Hướng xử lý:

- Thêm worker unit test và AWS smoke check cho audit item fields.

### P2: chưa thấy worker tests

Static review chưa tìm thấy worker-specific tests tương đương Telemetry API tests.

Tác động:

- Dễ regression ở AMP parsing, AI response validation, idempotency.

Hướng xử lý:

- Thêm assert-based/unit tests cho parse, align/impute, AI validation, audit item build và SNS condition.

---

## 6. Phụ thuộc liên epic

- EPIC-02 phải deploy real AI Engine, không dùng placeholder.
- EPIC-03 phải ghi metrics vào AMP để Worker query có dữ liệu.
- EPIC-06 phải deploy real image tags và chạy smoke thật.
- EPIC-07 phải có E2E coverage cho SQS -> Worker -> AI -> audit.
- EPIC-08 cost breaker có thể ảnh hưởng Worker/AI desired count trong lúc test.

---

## 7. Hạng mục chấp nhận chưa hoàn tất

| Item | Status | Note |
|---|---:|---|
| Tuấn DynamoDB fallback policy table | `ACCEPTED-INCOMPLETE` | Terraform placeholder tồn tại và Worker đọc policy table nếu được cấu hình. Không tính là fail cho EPIC-04 trong report này. Evidence: `infra/terraform/modules/data/main.tf:58-61`, `src/prediction_worker/app.py:172`. |

---

## 8. Việc tiếp theo cho Jira

1. Resolve Worker -> AI auth model và cập nhật code/Terraform/contracts cùng lúc.
2. Deploy real AI Engine task thay cho placeholder command.
3. Thêm Worker unit tests cho AMP, AI validation, audit, SNS và idempotency.
4. Thêm E2E smoke: enqueue message -> Worker logs -> AI call -> audit row -> DLQ empty.
5. Verify SNS high-risk alert sau deploy.
6. Giữ fallback table là task riêng của Tuấn, nhưng guard behavior khi thiếu table phải rõ ràng.

---

## 9. Read-only verification commands

```bash
rg -n "query_range|signal_window|Authorization|X-Tenant-Id|fallback|put_item|ConditionExpression|sns.publish|lookback_window_minutes|execute-api" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/src/prediction_worker /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra/terraform/modules
```

```bash
rg -n "Authorization|SigV4|Depends|edge|/v1/predict|ai-engine" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/src/ai_engine /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/contracts
```

---

## 10. Kết luận cuối

EPIC-04 code đã tiến triển tốt và nhiều subtask runtime đã có implementation. Chưa pass vì auth/deploy reality vẫn không khớp: Worker ký sai target model, AI app không enforce, và ECS task còn placeholder. Cần fix blockers ở EPIC-02/EPIC-06 trước khi chạy E2E EPIC-04.
