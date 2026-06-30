# Evidence Index

Runtime evidence artifacts are stored under `evidence/logs/`.

## Final evidence status

**Status:** accepted for capstone demo / mentor review with documented k6 caveat.

Core pass evidence:

```text
Custom HTTPS domain works.
Telemetry ingest works for tenant demo-tenant-001.
3 services covered: ledger, payment-gw, fraud-detector.
Worker reaches AI Engine from AMP signal windows.
Audit table contains AI_ENGINE + complete_window + ai_status_code=200 records.
3h 50 RPS ingest run sustained target load with p95 257 ms and 99.9998% accepted responses.
```

Caveat:

```text
3h k6 run had 5 dropped_iterations and 1 failed request out of 539,995 requests.
Project owner accepted this as pass for demo. Keep caveat visible; do not call it strict zero-drop k6 pass.
```

## Primary evidence files

| Purpose | File |
|---|---|
| 2m 50 RPS smoke summary | `evidence/logs/acceptance-50rps-2m-final-summary.json` |
| 3h 50 RPS final summary | `evidence/logs/acceptance-50rps-3h-final-summary.json` |
| 3h run log | `evidence/logs/acceptance-50rps-3h-domain-demo-tenant.log` |
| Prediction worker CloudWatch export | `evidence/logs/prediction-worker-recent.json` |
| AI Engine CloudWatch export | `evidence/logs/ai-engine-recent.json` |
| DynamoDB audit scan | `evidence/logs/audit-recent-scan.json` |
| Test evaluation report | `docs/07_test_eval_report.md` |

## 2m smoke result

Source: `acceptance-50rps-2m-final-summary.json`

```text
http_reqs: 6,001
rate: 49.910/s
http_req_failed: 0
p95 latency: 246.51 ms
dropped_iterations: 0
checks: 6,001 / 6,001
```

## 3h final load result

Source: `acceptance-50rps-3h-final-summary.json`

```text
http_reqs: 539,995
rate: 49.9986/s
http_req_failed: 1 / 539,995 = 0.000185%
p95 latency: 257.42 ms
max latency: 2.08 s
dropped_iterations: 5 / ~540,000 = 0.00093%
checks: 539,994 / 539,995 = 99.9998%
```

Interpretation:

```text
Operationally passed for demo. Strict k6 zero-drop threshold failed; caveat documented.
```

## AI path evidence

Source: `audit-recent-scan.json`, `prediction-worker-recent.json`, `ai-engine-recent.json`.

Latest good records include:

```text
2026-06-30T17:52:32Z fraud-detector AI_ENGINE complete_window ai_status_code=200
2026-06-30T17:52:33Z payment-gw     AI_ENGINE complete_window ai_status_code=200
2026-06-30T17:52:34Z ledger         AI_ENGINE complete_window ai_status_code=200
2026-06-30T17:57:31Z fraud-detector AI_ENGINE complete_window ai_status_code=200
2026-06-30T17:57:32Z payment-gw     AI_ENGINE complete_window ai_status_code=200
2026-06-30T17:57:34Z ledger         AI_ENGINE complete_window ai_status_code=200
```

Summary:

```text
AI_ENGINE + complete_window + 200: 6 records
AI_ENGINE + partial_window + 200: 3 records
Services covered: ledger, payment-gw, fraud-detector
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

## Superseded diagnostics

These files are kept only as diagnostics and must not be used as final pass evidence:

```text
acceptance-50rps-*insecure*
acceptance-50rps-*domain-multiservice*
acceptance-50rps-*domain.log without demo tenant
```

## Final wording

Use:

```text
The final live run sustained 50 RPS for 3 hours over the custom HTTPS domain with 539,995 ingest requests, 99.9998% accepted responses, and p95 latency of 257 ms. Worker and audit evidence show AI_ENGINE complete-window predictions for all three services. Five k6 dropped iterations were observed and documented as an operationally negligible caveat.
```

Do not use:

```text
zero-drop strict k6 pass
AMP received 50 samples/sec
Cost Explorer proves full-month actual spend from same-day data
Cross-account tenant isolation tested
```
