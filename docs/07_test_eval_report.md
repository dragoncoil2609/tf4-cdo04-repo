# Test & Eval Report - Task force 4 · CDO Foresight Lens

<!-- Doc owner: Nhóm CDO / QA Lead
     Status: FINAL LIVE EVIDENCE CAPTURED - accepted for demo with noted k6 caveat
     Region: us-east-1
     Environment: sandbox
     Date updated: 2026-07-02 -->

## 1. Executive verdict

**Verdict: PASS cho capstone demo / mentor review, với documented k6 caveat.**

Live evidence chứng minh:

```text
Telemetry ingest through API Gateway AWS_IAM works.
3 canonical services emit metrics for tenant demo-tenant-001.
Prediction worker reads AMP and reaches AI Engine.
DynamoDB audit contains AI_ENGINE + complete_window + ai_status_code=200 records.
3h 50 RPS ingest run sustained target load with excellent latency/error SLOs.
```

Caveat được giữ rõ ràng:

```text
3h k6 exited 99 because strict dropped_iterations count<1 threshold failed.
Observed 27 dropped iterations and 19 failed requests out of 539,974 requests.
Failure rate was 0.0035%, below the <1% gate.
Do not describe it as a zero-drop strict k6 pass.
```

## 2. Evidence files

Runtime evidence lives under `evidence/logs/`.

| Evidence | File |
|---|---|
| Curated live evidence index | `evidence/logs/live-testing-20260701-141831/curated/README.md` |
| 2m 50 RPS smoke summary | `evidence/logs/live-testing-20260701-141831/curated/k6-50rps-2m-summary.json` |
| 3h 50 RPS final summary | `evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-summary.json` |
| Trimmed 3h k6 final log | `evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-log-thresholds.txt` |
| SigV4 smoke proof | `evidence/logs/live-testing-20260701-141831/curated/preflight-post-apply-smoke-signed.log` |
| Final poll summary | `evidence/logs/live-testing-20260701-141831/curated/poll-final-summary.tsv` |
| DynamoDB audit samples | `evidence/logs/live-testing-20260701-141831/curated/poll-*-audit-sample.json` |
| AMP query samples | `evidence/logs/live-testing-20260701-141831/curated/amp-sample-*.json` |

Superseded evidence remains diagnostic only:

```text
acceptance-50rps-*insecure*
acceptance-50rps-*domain-multiservice*
acceptance-50rps-*domain.log without demo tenant
CloudWatch tail/error captures from live-testing-20260701-141831
```

## 3. Preflight evidence

Source: `preflight-post-apply-smoke-signed.log`.

| Probe | Result | Verdict |
|---|---:|---|
| `/health` | 200 | PASS |
| unsigned `POST /v1/ingest` | 403 | PASS |
| signed `POST /v1/ingest` | 201 | PASS |
| unsigned `POST /v1/predict` | 403 | PASS |
| signed `POST /v1/predict` | 200 | PASS |
| AMP query endpoint | reachable | PASS |
| ECS services after wait | stable | PASS |
| DLQ baseline | 652 pre-existing | caveat baseline |

## 4. Load and ingest evidence

### 4.1 2m smoke gate

Run target:

```text
URL=https://jljhxtkm7f.execute-api.us-east-1.amazonaws.com
TENANT_ID=demo-tenant-001
SERVICE_IDS=ledger,payment-gw,fraud-detector
RATE=50
DURATION=2m
```

Result from `k6-50rps-2m-summary.json`:

| Metric | Result | Gate |
|---|---:|---|
| HTTP requests | 5,999 | ok |
| Sustained RPS | 49.894/s | ok |
| p95 latency | 258.94 ms | < 1000 ms |
| Failed requests | 0 | < 1% |
| Dropped iterations | 2 | caveat |
| Checks | 5,999 / 5,999 | pass |

### 4.2 3h final 50 RPS gate

Run target:

```text
URL=https://jljhxtkm7f.execute-api.us-east-1.amazonaws.com
TENANT_ID=demo-tenant-001
SERVICE_IDS=ledger,payment-gw,fraud-detector
RATE=50
DURATION=3h
```

Result from `k6-50rps-3h-summary.json`:

| Metric | Result | Gate / interpretation |
|---|---:|---|
| HTTP requests | 539,974 | ~540k sustained ingest calls |
| Sustained RPS | 49.9965/s | target met |
| p95 latency | 256.19 ms | pass, < 1000 ms |
| Avg latency | 249.00 ms | ok |
| Max latency | 19.38 s | isolated driver/network spike |
| Failed requests | 19 / 539,974 = 0.0035% | pass, < 1% |
| Checks | 539,955 / 539,974 = 99.9965% | pass |
| Dropped iterations | 27 | strict zero-drop caveat |
| k6 exit code | 99 | caused by strict dropped_iterations threshold |

Mentor-facing wording (trình bày với mentor):

```text
The 3-hour run sustained 50 RPS over 539,974 ingest requests with p95 latency 256 ms and a 0.0035% failed-request rate. Twenty-seven local k6 dropped iterations occurred over the 3-hour run; this is documented as a strict-threshold caveat and not hidden.
```

## 5. Telemetry path semantics

Current runtime path:

```text
producer/k6/service -> POST /v1/ingest
telemetry-api validates payload and updates in-memory Prometheus Gauge
ADOT sidecar scrapes http://localhost:8080/metrics every 15s
ADOT remote_writes scraped samples to AMP
prediction-worker query_range reads AMP
```

Phạm vi quan trọng:

```text
50 RPS k6 validates ingest API headroom.
It does not prove AMP stores 50 event samples/sec.
ADOT stores latest gauge snapshots per scrape interval, which is correct for 1-minute prediction buckets.
```

Telemetry cadence demo thông thường:

```text
3 services x 7 signals / 60s = 0.35 RPS
50 RPS = about 143x demo producer headroom
```

## 6. AI prediction evidence

DynamoDB audit query shows live records for tenant `demo-tenant-001` and all 3 canonical services.

Latest good AI complete-window records:

| Time UTC | Service | Source | Evidence | AI status |
|---|---|---|---|---:|
| 2026-07-01T17:37:31.904208+00:00 | fraud-detector | AI_ENGINE | complete_window | 200 |
| 2026-07-01T17:37:32.860310+00:00 | payment-gw | AI_ENGINE | complete_window | 200 |
| 2026-07-01T17:37:34.677907+00:00 | ledger | AI_ENGINE | complete_window | 200 |

Audit evolution during run:

```text
poll-01: STATIC_THRESHOLD_FALLBACK partial_window ai_status_code=0
poll-03: AI_ENGINE partial_window ai_status_code=200
poll-05: AI_ENGINE complete_window ai_status_code=200
final:   AI_ENGINE complete_window ai_status_code=200 for all 3 services
```

Điều này chứng minh cold-start gap handling và full AI path thành công sau khi AMP window fills.

## 7. Runtime health evidence

Final poll:

| Check | Result | Verdict |
|---|---:|---|
| ECS bad services | 0 | PASS |
| SQS main visible/inflight | 0 / 0 | PASS |
| DLQ visible/inflight | 652 / 0 | unchanged baseline |
| AMP instant queries | 20 / 21 present | caveat |
| DynamoDB latest audit rows | 30 queried | PASS |

Earlier polls had AMP 21/21 present. Final 20/21 is a point-in-time query caveat, not a worker failure because final audit still shows complete-window AI_ENGINE records.

## 8. Worker and AI Engine log caveat

CloudWatch tail/error artifacts from `live-testing-20260701-141831` did not contain useful service logs because collection failed/no useful content was produced.

Use these artifacts as pass evidence instead:

```text
k6 summaries
preflight smoke
ECS service state
SQS main/DLQ depth
AMP query responses
DynamoDB audit records
```

Do not claim CloudWatch service-log review as pass evidence for this run.

## 9. Security and isolation evidence

Được cover bởi code/tests và smoke design:

| Probe | Status |
|---|---|
| `POST /v1/ingest` requires API Gateway SigV4 | preflight unsigned 403, signed 201 |
| `POST /v1/predict` requires API Gateway SigV4 | preflight unsigned 403, signed 200 |
| Missing `X-Tenant-Id` rejected | covered by Telemetry API tests |
| Header/body tenant mismatch rejected | covered by Telemetry API tests |
| PII/high-cardinality label rejected | covered by Telemetry API tests |
| Public `/metrics` not routed | smoke/design coverage |
| Cross-account tenant isolation | N/A in single sandbox |

## 10. Cost evidence

Cost Explorer actuals chậm 24-48h, nên same-day run không thể prove full billing impact.

Mentor-safe statement (trình bày với mentor):

```text
Budget guardrail and cost breaker are configured. Cost Explorer snapshot is delayed supporting evidence. Projected monthly cost remains under $200 based on deployed resource sizing.
```

## 11. Final gate table

| Gate group | Evidence | Verdict |
|---|---|---|
| Unit/contract | pytest previously passed: 155 passed, 1 warning | PASS |
| API Gateway smoke | `/health` 200, unsigned protected routes 403, signed routes pass | PASS |
| Ingest smoke | 2m 50 RPS, 5,999 requests, 0 failures | PASS with drop caveat |
| 3h ingest load | 539,974 requests, p95 256 ms, 19 failures, 27 drops | PASS with caveat |
| 3 services | `ledger`, `payment-gw`, `fraud-detector` | PASS |
| AI path | `AI_ENGINE`, `complete_window`, `ai_status_code=200` | PASS |
| Worker gap logic | fallback -> partial AI -> complete AI transition captured | PASS |
| DLQ/queue | main queue 0/0, DLQ unchanged at 652 | PASS |
| Cost guard | budget/cost breaker configured | PASS |

## 12. Remaining caveats

Không overclaim các điểm sau:

```text
- 3h k6 was accepted despite 27 dropped iterations; not strict zero-drop k6 pass.
- 19 failed requests were observed; failure rate still passed the <1% gate.
- CloudWatch log collection did not yield useful service logs for this live run.
- Final AMP instant query was 20/21; previous polls were 21/21 and final audit was healthy.
- 50 RPS is ingest API headroom, not normal telemetry cadence and not AMP event persistence rate.
- 100 RPS acceptance was not rerun in this final evidence set.
- Cross-account tenant isolation is N/A in this single sandbox.
- Cost Explorer same-day actuals are delayed supporting evidence only.
```

## Related documents

- [`02_infra_design.md`](02_infra_design.md)
- [`03_security_design.md`](03_security_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`../tests/README.md`](../tests/README.md)
- [`../evidence/README.md`](../evidence/README.md)
