# Báo cáo QA EPIC-03: Telemetry API & AMP Ingestion

Ngày review: 2026-06-29

Phạm vi QA:

- Telemetry API `POST /v1/ingest`
- schema validation
- PII/high-cardinality denylist
- metric allowlist
- AMP ingestion path
- S3 failure buffer
- `/health`
- k6/test coverage liên quan

Không chạy runtime/API thật. Chỉ review tĩnh từ code, docs và contracts.

---

## 1. Kết luận tổng quan

Status: `PARTIAL`.

Telemetry API đã có route `/v1/ingest`, validation, label/metric guardrails, failure buffer, `/health` và tests. EPIC-03 vẫn chưa pass vì AMP ingestion path chưa phải Prometheus `remote_write` thật như docs/contracts mô tả. Adapter hiện tại gửi JSON HTTP/stub behavior, nên chưa chứng minh được remote_write protobuf/snappy/SigV4. k6 script cũng đã stale vì vẫn gọi `/v1/telemetry` thay vì `/v1/ingest`.

---

## 2. Phạm vi Jira

| Jira ID | Title | Status |
|---|---|---:|
| CPOA-52 | EPIC-03 - Telemetry API & AMP Ingestion | `PARTIAL` |
| CPOA-53 | POST `/v1/ingest` | `PASS` |
| CPOA-54 | schema validation | `PASS` |
| CPOA-55 | PII and label denylist | `PASS` |
| CPOA-56 | metric allowlist | `PASS` |
| CPOA-57 | ADOT/Prometheus Agent remote_write path | `FAIL` |
| CPOA-58 | S3 failure buffer | `PARTIAL` |
| CPOA-59 | `/health` | `PASS` |

Evidence: `docs/jira_task_collection_full.md:70`.

---

## 3. Status từng subtask

| Subtask | Status | QA note |
|---|---:|---|
| `POST /v1/ingest` | `PASS` | Route đã tồn tại. |
| Schema validation | `PASS` | Có mandatory fields và Pydantic validation. |
| PII / label denylist | `PASS` | Có denylist và cardinality checks. |
| Metric allowlist | `PASS` | Có allowed metrics validation. |
| AMP remote_write | `FAIL` | Adapter dùng app-level JSON HTTP/stub, chưa phải Prometheus remote_write thật. |
| S3 failure buffer | `PARTIAL` | Có code buffer, nhưng IAM/runtime wiring và E2E proof vẫn cần kiểm tra. |
| `/health` | `PASS` | Route đã tồn tại. |

---

## 4. Kỳ vọng và thực tế

Kỳ vọng:

```text
Client
  -> POST /v1/ingest
  -> validate tenant/schema/metric labels
  -> convert telemetry to Prometheus-compatible samples
  -> ADOT/Prometheus remote_write to AMP
  -> fallback S3 failure buffer if AMP write fails
```

Thực tế:

```text
POST /v1/ingest exists
schema/denylist/allowlist exists
failure buffer code exists
AMP adapter path appears JSON HTTP/stub, not true remote_write
k6 test uses old /v1/telemetry path
```

---

## 5. Evidence đã kiểm tra

Evidence đạt PASS:

- `/v1/ingest` route: `src/telemetry_api/routes/ingest.py:26`
- mandatory field precheck: `src/telemetry_api/routes/ingest.py:49`
- schema validation: `src/telemetry_api/schemas/telemetry.py:23`
- metric allowlist: `src/telemetry_api/validators/metrics.py:8`, `src/telemetry_api/validators/metrics.py:25`
- PII/high-cardinality denylist: `src/telemetry_api/validators/labels.py:9`, `src/telemetry_api/validators/labels.py:25`, `src/telemetry_api/validators/labels.py:131`
- S3 failure buffer path: `src/telemetry_api/services/ingest_service.py:165`
- `/health`: `src/telemetry_api/routes/health.py:11`
- tests cover ingest validation: `src/telemetry_api/tests/telemetry_api/test_ingest_api.py:79`

Evidence fail/gap:

- AMP adapter JSON HTTP path: `src/telemetry_api/adapters/amp_delivery_adapter.py:43-52`
- docs mention ingest -> remote_write -> AMP: `docs/02_infra_design.md:59`, `docs/02_infra_design.md:248`
- telemetry contract defines signals/fields: `contracts/telemetry-contract.md:20`, `contracts/telemetry-contract.md:242`
- k6 stale endpoint: `tests/k6/sc02_spike.js:40`
- normal route returns `201`, k6 expects `202`: `src/telemetry_api/routes/ingest.py:116`, `tests/k6/sc02_spike.js:66`

---

## 6. Findings theo severity

### P0: AMP ingestion chưa phải Prometheus `remote_write`

Docs/contracts nói AMP ingestion đi qua ADOT/Prometheus remote_write, nhưng app adapter hiện chưa chứng minh được format/transport đó.

Evidence:

- `src/telemetry_api/adapters/amp_delivery_adapter.py:43-52`
- `docs/02_infra_design.md:59`
- `docs/02_infra_design.md:248`

Tác động:

- Metrics có thể không vào AMP thật.
- Prediction Worker query AMP có thể không thấy expected signals.
- EPIC-04 phụ thuộc EPIC-03 nên E2E có thể fail.

Hướng xử lý:

1. Dùng ADOT Collector sidecar/agent và expose app metrics theo Prometheus format.
2. Hoặc implement direct AMP remote_write đúng chuẩn: SigV4 + snappy-compressed protobuf remote_write format.
3. Chỉ update docs nếu product chấp nhận non-AMP stub path cho demo.

### P1: k6 script dùng path/status đã stale

Load test script gọi `/v1/telemetry`, trong khi contract/route hiện tại là `/v1/ingest`.

Evidence:

- `tests/k6/sc02_spike.js:40`
- `src/telemetry_api/routes/ingest.py:26`

Hướng xử lý:

- Đổi path sang `/v1/ingest`.
- Assert `201` cho accepted path và chỉ dùng `202` cho buffered path khi đúng case.

### P1: S3 failure buffer cần runtime proof

Code path đã có, nhưng report chưa có evidence sau deploy để chứng minh IAM/env/bucket write hoạt động.

Evidence:

- `src/telemetry_api/services/ingest_service.py:165`
- docs require failure buffer: `docs/02_infra_design.md:410-416`

Hướng xử lý:

- Thêm controlled test: ép AMP failure, assert S3 object được ghi và response status/metrics khớp contract.

### P2: rủi ro legacy route/file

Repo vẫn còn dấu hiệu stale quanh `/v1/telemetry` trong tests/legacy app. Điều này dễ gây nhầm cho dev.

Evidence:

- `tests/k6/sc02_spike.js:40`
- likely legacy `src/telemetry_api/app.py` path from stale scan.

Hướng xử lý:

- Xác nhận Docker runtime trước, rồi remove legacy file nếu không dùng.
- Giữ `/v1/ingest` là public contract duy nhất.

---

## 7. Phụ thuộc liên epic

- EPIC-02 phải deploy Telemetry API container đúng cách.
- EPIC-04 cần data tồn tại trong AMP để Worker `query_range` có ý nghĩa.
- EPIC-07 phụ thuộc k6 và test report đang current.
- EPIC-06 phải install service deps và chạy tests/smoke thật.

---

## 8. Việc tiếp theo cho Jira

1. Chốt final AMP write model: ADOT Collector hoặc direct remote_write.
2. Implement real AMP remote_write path, hoặc update contract nếu demo dùng mock path.
3. Thêm integration test cho AMP write hoặc ADOT scrape/remote_write config.
4. Sửa k6 route/status assertions.
5. Thêm failure-buffer E2E test.
6. Xóa hoặc cập nhật các reference `/v1/telemetry` đã stale.

---

## 9. Read-only verification commands

```bash
rg -n "remote_write|AMP|aps|/v1/ingest|/v1/telemetry|X-Tenant-Id|denylist|high-cardinality|buffered|s3" /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/src/telemetry_api /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/contracts /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/docs /c/Users/thanh/Desktop/workspace/phase2-capstone/tf4-cdo04-repo/tests
```

---

## 10. Kết luận cuối

EPIC-03 chưa pass. API contract/validation khá ổn, nhưng core AMP ingestion claim chưa đúng với docs. Cần fix remote_write path trước, sau đó cập nhật tests/k6.
