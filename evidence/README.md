# Evidence Index

Runtime evidence artifacts are stored under `evidence/logs/`.

## Folder policy

```text
evidence/logs/live-testing-20260701-141831/curated/  # final pass evidence
evidence/logs/diagnostic/                            # non-final troubleshooting context
```

Everything else in `evidence/logs/` should be treated as noise unless this README lists it.

## Final evidence status

**Status:** accepted for capstone demo / mentor review with documented k6 caveat.

Latest curated live run:

```text
evidence/logs/live-testing-20260701-141831/curated/
```

Core pass evidence:

```text
API Gateway AWS_IAM public ingress works.
Telemetry ingest works for tenant demo-tenant-001.
3 services covered: ledger, payment-gw, fraud-detector.
Worker reads AMP windows and reaches AI Engine.
DynamoDB audit contains AI_ENGINE + complete_window + ai_status_code=200 records.
3h 50 RPS ingest run sustained target load with p95 256.19 ms.
```

Caveat:

```text
3h k6 run exited 99 because strict dropped_iterations count<1 threshold failed.
Observed 27 dropped iterations and 19 failed requests out of 539,974 requests.
Failure rate stayed 0.0035%, below the k6 http_req_failed < 1% threshold.
Do not call it a strict zero-drop k6 pass.
```

## Primary evidence files

| Purpose | File |
|---|---|
| Curated evidence index | `evidence/logs/live-testing-20260701-141831/curated/README.md` |
| 2m 50 RPS smoke summary | `evidence/logs/live-testing-20260701-141831/curated/k6-50rps-2m-summary.json` |
| 3h 50 RPS final summary | `evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-summary.json` |
| Trimmed 3h k6 final log | `evidence/logs/live-testing-20260701-141831/curated/k6-50rps-3h-log-thresholds.txt` |
| SigV4 smoke proof | `evidence/logs/live-testing-20260701-141831/curated/preflight-post-apply-smoke-signed.log` |
| ECS stable before load | `evidence/logs/live-testing-20260701-141831/curated/preflight-ecs-stable-after-wait.json` |
| Final poll summary | `evidence/logs/live-testing-20260701-141831/curated/poll-final-summary.tsv` |
| DynamoDB audit samples | `evidence/logs/live-testing-20260701-141831/curated/poll-*-audit-sample.json` |
| AMP samples | `evidence/logs/live-testing-20260701-141831/curated/amp-sample-*.json` |
| Test evaluation report | `docs/07_test_eval_report.md` |

## Preflight result

Source: `preflight-post-apply-smoke-signed.log`

```text
/health: 200
unsigned POST /v1/ingest: 403
signed POST /v1/ingest: 201
unsigned POST /v1/predict: 403
signed POST /v1/predict: 200
AMP query endpoint: reachable
ECS services: stable after wait
DLQ baseline: 652 pre-existing messages
```

## 2m smoke result

Source: `k6-50rps-2m-summary.json`

```text
http_reqs: 5,999
rate: 49.894/s
http_req_failed: 0
p95 latency: 258.94 ms
dropped_iterations: 2
checks: 5,999 / 5,999
```

Interpretation:

```text
Application path passed. Strict zero-drop k6 threshold failed from 2 dropped iterations.
```

## 3h final load result

Source: `k6-50rps-3h-summary.json`

```text
http_reqs: 539,974
rate: 49.9965/s
http_req_failed: 19 / 539,974 = 0.0035%
p95 latency: 256.19 ms
avg latency: 249.00 ms
max latency: 19.38 s
dropped_iterations: 27
checks: 539,955 / 539,974 = 99.9965%
```

Interpretation:

```text
Operationally passed for demo. Strict zero-drop k6 threshold failed; caveat documented.
```

## AI path evidence

Source: `poll-final-summary.tsv` and `poll-final-audit-sample.json`.

Latest good records:

```text
2026-07-01T17:37:31.904208+00:00 fraud-detector AI_ENGINE complete_window ai_status_code=200
2026-07-01T17:37:32.860310+00:00 payment-gw     AI_ENGINE complete_window ai_status_code=200
2026-07-01T17:37:34.677907+00:00 ledger         AI_ENGINE complete_window ai_status_code=200
```

Evolution during run:

```text
poll-01: STATIC_THRESHOLD_FALLBACK partial_window ai_status_code=0
poll-03: AI_ENGINE partial_window ai_status_code=200
poll-05: AI_ENGINE complete_window ai_status_code=200
final:   AI_ENGINE complete_window ai_status_code=200 for all 3 services
```

## Runtime health evidence

Final poll:

```text
ECS bad services: 0
SQS main: 0 visible / 0 inflight
DLQ: 652 visible / 0 inflight, unchanged from baseline
AMP: 20 present / 1 missing in final instant query
DynamoDB audit count: 30 latest queried
```

Earlier polls showed AMP 21/21 present; final 20/21 is a point-in-time query caveat, not a worker failure.

## Diagnostic evidence kept

These files are kept for root-cause context, not final acceptance proof:

```text
evidence/logs/diagnostic/README.md
evidence/logs/diagnostic/ai-engine-recent.json
evidence/logs/diagnostic/audit-recent-scan.json
evidence/logs/diagnostic/final-smoke.log
evidence/logs/diagnostic/prediction-worker-recent.json
```

## Deleted noise

Removed from `evidence/logs/`:

```text
acceptance-50rps-* old domain/insecure runs
raw live-testing poll-* directories
raw live-testing duplicate top-level files
full k6-50rps-3h.log
noisy CloudWatch tail/error/stderr captures
credential/token files
```

## Telemetry path caveat

Current production-like telemetry path:

```text
producer/k6/service -> POST /v1/ingest
telemetry-api validates payload and updates Prometheus Gauge
ADOT sidecar scrapes localhost:8080/metrics every 15s
ADOT remote_writes to AMP
prediction-worker query_range reads AMP
```

Therefore:

```text
50 RPS validates ingest API headroom.
It does not prove AMP persisted 50 event samples/sec.
Gauge + ADOT scrape is correct for 1-minute prediction buckets.
```

## Log collection caveat

CloudWatch tail/error artifacts from this live run did not contain useful service logs because collection failed/no useful content was produced. Do not claim CloudWatch log review as pass evidence for this run. Use k6 summaries, ECS service state, SQS depth, AMP responses, and DynamoDB audit records as proof.

## Final wording

Use:

```text
The final live run sustained 50 RPS for 3 hours through API Gateway AWS_IAM ingress with 539,974 ingest requests, p95 latency of 256 ms, and a 0.0035% failed-request rate. Worker and audit evidence show AI_ENGINE complete-window predictions for all three services. Twenty-seven k6 dropped iterations were observed and documented as the reason the strict zero-drop k6 threshold returned exit code 99.
```

Do not use:

```text
zero-drop strict k6 pass
CloudWatch logs prove service health for this run
AMP received 50 samples/sec
Cost Explorer proves full-month actual spend from same-day data
Cross-account tenant isolation tested
```
