# Báo cáo QA EPIC-07: Observability & Testing

Ngày review: 2026-06-29

Phạm vi QA:

- CloudWatch dashboard
- CloudWatch alarms
- SNS alert channel test evidence
- PromQL evidence snippets
- k6 scenarios SC-01..SC-04
- multi-tenant isolation test
- unit/integration test wiring
- test/eval report quality

Chỉ review tĩnh. Không chạy load test, không gọi AWS.

---

## 1. Kết luận tổng quan

Status: `PARTIAL`.

Terraform đã có các thành phần CloudWatch alarms, dashboard và SNS; ứng dụng cũng đã có test cho Telemetry API và AI Engine. Tuy vậy, EPIC-07 chưa pass vì test/eval report vẫn ở trạng thái draft và còn placeholders, coverage k6 còn thiếu và stale, smoke trong CI vẫn là placeholder, multi-tenant isolation chưa có bằng chứng chạy được, và chưa có evidence PromQL/E2E được đo thực tế.

---

## 2. Phạm vi Jira

| Jira ID | Title | Status |
|---|---|---:|
| CPOA-88 | EPIC-07 - Observability & Testing | `PARTIAL` |
| CPOA-89 | CloudWatch dashboard | `PASS` |
| CPOA-90 | CloudWatch alarms | `PASS` |
| CPOA-91 | SNS alert channel test | `NOT VERIFIABLE STATICALLY` |
| CPOA-92 | PromQL evidence snippets | `PARTIAL` |
| CPOA-93 | k6 SC-01 | `NOT IMPLEMENTED` |
| CPOA-94 | k6 SC-02 | `PARTIAL` |
| CPOA-95 | SC-03 | `NOT IMPLEMENTED` |
| CPOA-96 | SC-04 | `NOT IMPLEMENTED` |
| CPOA-97 | multi-tenant isolation test | `NOT IMPLEMENTED` |

Evidence: `docs/jira_task_collection_full.md:178`.

---

## 3. Kỳ vọng vs thực tế

Kỳ vọng:

```text
CloudWatch dashboard + alarms exist
SNS channel tested
PromQL snippets captured as evidence
k6 SC-01..SC-04 runnable
multi-tenant isolation test runnable
CI runs real tests/smoke
Test report contains measured results
```

Thực tế:

```text
Dashboard/alarms exist in Terraform
Some app tests exist
Only one k6 script found and it calls stale endpoint
Test/eval report says draft/not run
CI smoke is echo
Measured evidence missing
```

---

## 4. Evidence đã kiểm tra

Evidence đạt PASS/PARTIAL:

- Operational SNS/topic/alarms module: `infra/terraform/modules/observability/main.tf:51`
- ALB/ECS/SQS/AI alarms: `infra/terraform/modules/observability/alarms.tf:10`, `infra/terraform/modules/observability/alarms.tf:136`, `infra/terraform/modules/observability/alarms.tf:236`
- Cost/ops dashboard: `infra/terraform/modules/observability/cost_dashboard.tf:57`
- Telemetry API tests: `src/telemetry_api/tests/telemetry_api/test_ingest_api.py:79`
- AI API tests: `src/ai_engine/tests/test_api.py`
- one k6 script: `tests/k6/sc02_spike.js:1`

Evidence fail/gap:

- test/eval report draft/not run: `docs/07_test_eval_report.md:3-5`, `docs/07_test_eval_report.md:273-276`
- placeholder coverage: `docs/07_test_eval_report.md:58`
- scenario definitions but no measured proof: `docs/07_test_eval_report.md:60`, `docs/07_test_eval_report.md:87`
- k6 wrong endpoint: `tests/k6/sc02_spike.js:40`
- k6 status mismatch: `tests/k6/sc02_spike.js:66`, `src/telemetry_api/routes/ingest.py:116`
- CI smoke placeholder: `.github/workflows/deploy.yml:176-182`
- top-level placeholder test: `tests/test_basic.py:1-2`

---

## 5. Findings theo severity

### P0: CI smoke không phải smoke test

Deploy workflow báo smoke success nhưng không gọi ứng dụng đã deploy.

Evidence: `.github/workflows/deploy.yml:176-182`.

Tác động:

- Deploy có thể vẫn xanh dù đường đi ALB/ECS/API/Worker bị lỗi.

Hướng xử lý:

- Thêm smoke thật:
  - get ALB DNS
  - call `/health` and `/v1/ingest`
  - check ECS service stable
  - check SQS/DLQ depth
  - tail relevant logs or query CloudWatch metric.

### P1: coverage k6 chưa đủ và đã stale

Chỉ tìm thấy script SC-02. Script này gọi `/v1/telemetry`, không phải `/v1/ingest` hiện tại.

Evidence:

- `tests/k6/sc02_spike.js:40`
- `src/telemetry_api/routes/ingest.py:26`
- `docs/07_test_eval_report.md:60`

Hướng xử lý:

- Thêm script SC-01, SC-03, SC-04.
- Cập nhật endpoint và expected statuses cho SC-02.

### P1: test/eval report không thể dùng làm evidence pass

Report ghi rõ draft/not run và vẫn còn placeholders.

Evidence:

- `docs/07_test_eval_report.md:3-5`
- `docs/07_test_eval_report.md:58`
- `docs/07_test_eval_report.md:273-276`

Hướng xử lý:

- Thay placeholders bằng output đo được từ lần chạy thực tế.
- Gắn link CI run IDs, CloudWatch dashboards, k6 summary, PromQL results.

### P1: multi-tenant isolation mới dừng ở mức tài liệu

Tài liệu có nhắc multi-tenant isolation test, nhưng khi quét tĩnh không tìm thấy test chạy được.

Evidence:

- `docs/07_test_eval_report.md:250`
- `docs/07_test_eval_report.md:257`

Hướng xử lý:

- Thêm test: tenant A không thể query hoặc quan sát dữ liệu tenant B qua API/Worker/audit path.

### P2: unit test placeholder tạo cảm giác an toàn giả

Pytest ở top-level có thể pass chỉ với `assert True`.

Evidence: `tests/test_basic.py:1-2`.

Hướng xử lý:

- Xóa placeholder hoặc thay bằng smoke/unit check có ý nghĩa.

---

## 6. Phụ thuộc chéo giữa các epic

- EPIC-06 phải chạy tests/smoke đúng cách.
- EPIC-03 phải sửa AMP ingestion trước khi evidence PromQL có ý nghĩa.
- EPIC-04 phải pass Worker E2E trước khi có thể xác thực observability cho SQS/DLQ/audit.
- EPIC-08 budgets/cost breaker có thể làm thay đổi service desired counts trong lúc test.

---

## 7. Việc tiếp theo cho Jira

1. Thay CI smoke echo bằng smoke script thật.
2. Thêm hoặc sửa k6 SC-01..SC-04.
3. Thêm multi-tenant isolation test.
4. Cập nhật `docs/07_test_eval_report.md` chỉ với measured evidence.
5. Xóa placeholder `tests/test_basic.py`.
6. Thêm PromQL snippets từ AMP workspace thật sau deploy.
7. Ghi nhận kết quả xác nhận/test của SNS alert channel.

---

## 8. Read-only verification commands

```bash
rg -n "/v1/telemetry|/v1/ingest|Dashboard|Alarm|Budget|retention|cardinality|SC-0[1-4]|<X>|DRAFT|placeholder|smoke" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/tests /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/docs /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/infra/terraform/modules/observability /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/.github/workflows
```

---

## 9. Kết luận cuối

EPIC-07 chưa pass. Observability resources đã có, nhưng phần testing và evidence vẫn chưa đủ. Ưu tiên sửa smoke, k6 và evidence report vì trạng thái "green" hiện tại chưa chứng minh hệ thống chạy đúng.
