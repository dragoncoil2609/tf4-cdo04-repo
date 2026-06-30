# Test & Eval Report - Task force 4 · CDO Foresight Lens

<!-- Doc owner: Nhóm CDO / QA Lead
     Status: FINAL LIVE EVIDENCE CAPTURED - accepted for demo with noted k6 caveat
     Region: us-east-1
     Environment: sandbox
     Date updated: 2026-07-01 -->

## 1. Executive verdict

**Verdict: PASS for capstone demo / mentor review, with documented k6 caveat.**

Live evidence proves:

```text
Telemetry ingest over custom HTTPS domain works.
3 canonical services emit metrics for tenant demo-tenant-001.
Prediction worker reads AMP and reaches AI Engine.
DynamoDB audit contains AI_ENGINE + complete_window + ai_status_code=200 records.
3h 50 RPS ingest run sustained target load with excellent latency/error SLOs.
```

Caveat kept explicit:

```text
3h k6 had 5 dropped_iterations and 1 failed request out of 539,995 requests.
Operationally negligible; accepted by project owner as pass.
Do not describe it as a zero-drop strict k6 pass.
```

## 2. Evidence files

Runtime evidence lives under `evidence/logs/`.

| Evidence | File |
|---|---|
| 2m 50 RPS smoke summary | `evidence/logs/acceptance-50rps-2m-final-summary.json` |
| 3h 50 RPS final summary | `evidence/logs/acceptance-50rps-3h-final-summary.json` |
| 3h run log | `evidence/logs/acceptance-50rps-3h-domain-demo-tenant.log` |
| Worker CloudWatch export | `evidence/logs/prediction-worker-recent.json` |
| AI Engine CloudWatch export | `evidence/logs/ai-engine-recent.json` |
| DynamoDB audit scan | `evidence/logs/audit-recent-scan.json` |

Superseded evidence remains diagnostic only:

```text
acceptance-50rps-*insecure*
acceptance-50rps-*domain-multiservice*
acceptance-50rps-*domain.log without demo tenant
```

## 3. Load and ingest evidence

### 3.1 2m smoke gate

Run target:

```text
URL=https://xbrain26hackathon269.software
TENANT_ID=demo-tenant-001
SERVICE_IDS=ledger,payment-gw,fraud-detector
RATE=50
DURATION=2m
```

Result from `acceptance-50rps-2m-final-summary.json`:

| Metric | Result | Gate |
|---|---:|---|
| HTTP requests | 6,001 | ok |
| Sustained RPS | 49.910/s | ok |
| p95 latency | 246.51 ms | < 1000 ms |
| Failed requests | 0 | < 1% |
| Dropped iterations | 0 | strict pass |
| Checks | 6,001 / 6,001 | pass |

### 3.2 3h final 50 RPS gate

Run target:

```text
URL=https://xbrain26hackathon269.software
TENANT_ID=demo-tenant-001
SERVICE_IDS=ledger,payment-gw,fraud-detector
RATE=50
DURATION=3h
```

Result from `acceptance-50rps-3h-final-summary.json`:

| Metric | Result | Gate / interpretation |
|---|---:|---|
| HTTP requests | 539,995 | ~540k sustained ingest calls |
| Sustained RPS | 49.9986/s | target met |
| p95 latency | 257.42 ms | pass, < 1000 ms |
| Max latency | 2.08 s | isolated spike |
| Failed requests | 1 / 539,995 = 0.000185% | pass, < 1% |
| Checks | 539,994 / 539,995 = 99.9998% | pass |
| Dropped iterations | 5 / ~540,000 = 0.00093% | owner-accepted caveat |
| k6 exit code | 99 | caused by strict zero-drop threshold |

Mentor-facing wording:

```text
The 3-hour run sustained 50 RPS over 539,995 ingest requests with p95 latency 257 ms and 99.9998% accepted responses. Five local k6 dropped iterations occurred over the 3-hour run; this is documented as a negligible scheduler/headroom artifact and not hidden.
```

## 4. Telemetry path semantics

Current runtime path:

```text
producer/k6/service -> POST /v1/ingest
telemetry-api validates payload and updates in-memory Prometheus Gauge
ADOT sidecar scrapes http://localhost:8080/metrics every 15s
ADOT remote_writes scraped samples to AMP
prediction-worker query_range reads AMP
```

Important scope:

```text
50 RPS k6 validates ingest API headroom.
It does not prove AMP stores 50 event samples/sec.
ADOT stores latest gauge snapshots per scrape interval, which is correct for 1-minute prediction buckets.
```

Normal demo telemetry cadence:

```text
3 services x 7 signals / 60s = 0.35 RPS
50 RPS = about 143x demo producer headroom
```

## 5. AI prediction evidence

DynamoDB audit scan shows live records for tenant `demo-tenant-001` and all 3 canonical services.

Latest good AI complete-window records:

| Time UTC | Service | Source | Evidence | AI status | Latency | Decision |
|---|---|---|---|---:|---:|---|
| 2026-06-30T17:52:32Z | fraud-detector | AI_ENGINE | complete_window | 200 | 759 ms | SCALE_UP |
| 2026-06-30T17:52:33Z | payment-gw | AI_ENGINE | complete_window | 200 | 199 ms | SCALE_UP |
| 2026-06-30T17:52:34Z | ledger | AI_ENGINE | complete_window | 200 | 25 ms | SCALE_UP |
| 2026-06-30T17:57:31Z | fraud-detector | AI_ENGINE | complete_window | 200 | 258 ms | SCALE_UP |
| 2026-06-30T17:57:32Z | payment-gw | AI_ENGINE | complete_window | 200 | 19 ms | SCALE_UP |
| 2026-06-30T17:57:34Z | ledger | AI_ENGINE | complete_window | 200 | 19 ms | SCALE_UP |

Audit outcome summary from recent scan:

```text
AI_ENGINE + complete_window + 200: 6 records
AI_ENGINE + partial_window + 200: 3 records
3 services covered: ledger, payment-gw, fraud-detector
```

This fixes earlier false `gap_ratio=100%` issue; live worker now reaches AI Engine after AMP window fills.

## 6. Worker and AI Engine logs

Worker evidence:

```text
worker jobs started: 144
worker audit saved: 144
worker SNS alerts: 144
AI_ENGINE audit records: 9
complete_window AI records: 6
```

AI Engine evidence:

```text
GET /health 200: 965
POST /v1/predict 200: 6 in recent AI Engine logs
```

Known non-blocking log noise:

```text
envoy_bug removed guard envoy.reloadable_features.use_http_client_to_fetch_aws_credentials
```

Impact: did not block `/health` or `/v1/predict`.

## 7. Security and isolation evidence

Covered by code/tests and smoke design:

| Probe | Status |
|---|---|
| Missing `X-Tenant-Id` rejected | covered by Telemetry API tests |
| Header/body tenant mismatch rejected | covered by Telemetry API tests |
| PII/high-cardinality label rejected | covered by Telemetry API tests |
| Public `/metrics` not routed via ALB | ALB forwards only `/health` and `/v1/ingest` |
| Cross-account tenant isolation | N/A in single sandbox |

## 8. Cost evidence

Cost Explorer actuals lag 24-48h, so same-day run cannot prove full billing impact.

Mentor-safe statement:

```text
Budget guardrail and cost breaker are configured. Cost Explorer snapshot is delayed supporting evidence. Projected monthly cost remains under $200 based on deployed resource sizing.
```

## 9. Final gate table

| Gate group | Evidence | Verdict |
|---|---|---|
| Unit/contract | pytest previously passed: 155 passed, 1 warning | PASS |
| HTTPS smoke | custom domain `/health` 200, HTTP redirects to HTTPS | PASS |
| Ingest smoke | 2m 50 RPS, 6,001 requests, 0 failures, 0 drops | PASS |
| 3h ingest load | 539,995 requests, p95 257 ms, 1 failure, 5 drops | PASS with caveat |
| 3 services | `ledger`, `payment-gw`, `fraud-detector` | PASS |
| AI path | `AI_ENGINE`, `complete_window`, `ai_status_code=200` | PASS |
| Worker gap logic | latest gap no longer false 100%; complete_window records exist | PASS |
| DLQ/queue | no DLQ growth observed in current run context | PASS |
| Cost guard | budget/cost breaker configured | PASS |

## 10. Remaining caveats

Do not overclaim these:

```text
- 3h k6 was owner-accepted despite 5 dropped iterations; not strict zero-drop k6 pass.
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
