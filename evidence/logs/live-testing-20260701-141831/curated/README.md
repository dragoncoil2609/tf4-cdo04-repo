# Curated Live Testing Evidence — 2026-07-01

Source run folder: `evidence/logs/live-testing-20260701-141831/`.

This folder keeps high-signal artifacts from the API Gateway + internal ALB live test and excludes secrets/noisy raw logs.

## Result

```text
Preflight: /health 200, unsigned ingest/predict 403, signed ingest 201, signed predict 200, ECS stable.
2m k6: 5,999 requests, 0 failed, p95 258.94 ms, 2 dropped iterations.
3h k6: 539,974 requests, 19 failed (0.0035%), p95 256.19 ms, 27 dropped iterations.
Final pipeline: ECS stable, SQS main 0/0, DLQ 652/0 unchanged, audit AI_ENGINE complete_window ai_status_code=200 for ledger/payment-gw/fraud-detector.
```

## Files

| File | Why |
|---|---|
| `bootstrap.env.redacted` | Live endpoints/resource names with token value redacted. |
| `caller-identity.json` | AWS account/principal used for run. |
| `preflight-post-apply-smoke-signed.log` | SigV4 smoke proof for ingest and predict. |
| `preflight-ecs-stable-after-wait.json` | ECS stability before sustained load. |
| `k6-50rps-2m-summary.json` | 2m smoke summary. |
| `k6-50rps-3h-summary.json` | 3h sustained-load summary. |
| `k6-50rps-3h-log-thresholds.txt` | Trimmed k6 tail with final threshold/totals only. |
| `poll-01-summary.txt` | Cold-start fallback/partial-window evidence. |
| `poll-03-summary.tsv` | AI_ENGINE partial_window transition evidence. |
| `poll-05-summary.tsv` | AI_ENGINE complete_window transition evidence. |
| `poll-final-summary.tsv` | Final ECS/SQS/AMP/audit summary. |
| `poll-*-audit-sample.json` | Trimmed DynamoDB audit samples, first 3 rows each. |
| `amp-sample-*.json` | Representative AMP query responses. |
| `poll-methodology.md` | Accepted one-shot polling method, without credential-loading script. |

## Excluded

```text
credential env file (excluded)
tenant ingest token file (excluded)
full k6-50rps-3h.log
CloudWatch tail/error captures with no useful content
monitor-25m.sh (rejected long sleep loop)
post-2m*/ rootcause*/ poll-01-fixed/
```

## Caveats

```text
k6 exit code 99 came from strict dropped_iterations count<1 threshold.
19 failed requests were 0.0035% of 539,974 total requests.
DLQ 652 messages were pre-existing and did not grow.
CloudWatch log tail/error collection from this run did not produce useful service logs; use k6, ECS, SQS, AMP, and DynamoDB audit artifacts as proof.
```
