# Tests

Testing is acceptance-first. Stress scripts are diagnostic only; they never prove final acceptance by themselves.

## 1. Final acceptance entrypoint

Run this only when sandbox env vars are exported and you are ready for a 3.5h evidence run. Set `RUN_SINGLE_PIPELINE=1` only if you also want the older one-service acceptance script, adding about 125 minutes.

```bash
export AWS_REGION=us-east-1
export ALB_DNS_NAME=<alb-dns>
export ECS_CLUSTER_NAME=<cluster>
export TELEMETRY_API_SERVICE_NAME=<telemetry-service>
export PREDICTION_WORKER_SERVICE_NAME=<worker-service>
export AI_ENGINE_SERVICE_NAME=<ai-service>
export PREDICTION_QUEUE_URL=<queue-url>
export PREDICTION_QUEUE_DLQ_URL=<dlq-url>
export DYNAMODB_AUDIT_TABLE=<audit-table>
export AMP_QUERY_ENDPOINT=<amp-query-endpoint>
export AWS_ACCOUNT_ID=<account-id>
export BUDGET_NAME=tf4-cdo04-platform-budget-sandbox

bash tests/e2e/run_final_acceptance.sh
```

Skip flags are allowed for partial reruns only:

```bash
SKIP_SCENARIO_MATRIX=1 SKIP_K6=1 SKIP_COST=1 SKIP_SECURITY=1 bash tests/e2e/run_final_acceptance.sh
```

Skipped gate means skipped, not passed.

## 2. Acceptance gates

| Gate | Command | Evidence |
|---|---|---|
| Unit/contract | `PYTHONPATH=src/ai_engine:src pytest -q` | CI/local pytest output |
| Deploy smoke | `bash scripts/post_apply_smoke.sh` | `evidence/logs/final-smoke.log` |
| Single-service AI path | optional `RUN_SINGLE_PIPELINE=1 bash tests/e2e/run_final_acceptance.sh` or standalone `bash tests/e2e/acceptance_ai_pipeline.sh` | `acceptance-ai-send-message.json`, `acceptance-ai-audit-scan.json` |
| TF4 scenario matrix | `bash tests/e2e/tf4_scenario_matrix.sh` | `tf4-scenario-ground-truth.json`, `tf4-scenario-audit-scan.json`, `tf4-scenario-summary.json` |
| Eval metrics | `python tests/e2e/eval_report.py` | `logs/eval-report.json`, `logs/eval-report.md` |
| Low-RPS load | `k6 run tests/k6/acceptance_ingest.js ...` | `acceptance-50rps-summary.json`, `acceptance-100rps-summary.json` |
| Security/isolation | `bash tests/e2e/security_probes.sh` | `logs/security-probes.json` |
| Cost guard | AWS Budget + Cost Explorer collection | `budget-final.json`, `cost-explorer-final.json` |

## 3. Hard pass rules

Final acceptance requires all of these:

```text
prediction_source = AI_ENGINE
evidence_status = complete_window
ai_status_code = 200
```

And:

- 4 scenario decisions recorded: gradual drift, sudden spike, slow leak, noisy baseline.
- At least 3 services covered: `ledger`, `payment-gw`, `fraud-detector`.
- Recall / catch rate >= 80%.
- FP rate <= 12%.
- Precision, recall, F1, confusion matrix, Brier score reported.
- At least one >=2h scenario has lead time >=15 minutes before configured breach.
- k6 50/100 RPS: error rate <1%, p95 <1000ms, dropped iterations = 0.
- `/metrics` is not public.
- Tenant mismatch is rejected.
- Queue/DLQ has no unsafe growth.
- Budget/cost evidence stays under $200 cap.

## 4. Low-RPS load acceptance

Run after AI path and scenario matrix pass:

```bash
k6 run tests/k6/acceptance_ingest.js \
  -e TELEMETRY_API_HOST=<alb-dns> \
  -e RATE=50 \
  -e DURATION=10m \
  --summary-export evidence/logs/acceptance-50rps-summary.json

k6 run tests/k6/acceptance_ingest.js \
  -e TELEMETRY_API_HOST=<alb-dns> \
  -e RATE=100 \
  -e DURATION=10m \
  --summary-export evidence/logs/acceptance-100rps-summary.json
```

`tests/k6/acceptance_ingest.js` emits all 7 contracted signals with required labels. It is separate from stress scripts on purpose.

## 5. TF4 scenario matrix

`tests/e2e/tf4_scenario_matrix.sh` runs the mentor-facing scenario set:

| Scenario | Service | Expected |
|---|---|---|
| Gradual drift | `ledger` | anomaly |
| Sudden spike | `payment-gw` | anomaly |
| Slow leak | `fraud-detector` | anomaly |
| Noisy baseline | `fraud-detector` | no anomaly / low severity |

It seeds a real 120-minute warmup plus scenario window so AMP/ADOT/Worker path is proven with live data. No timestamp shortcut unless runtime supports reliable backfill later.

## 6. Ingest contract

- **Endpoint**: `POST /v1/ingest`
- **Payload**: `{ts, tenant_id, service_id, metric_type, value, labels}`
- **Headers**: `Content-Type: application/json`, `X-Tenant-Id: <tenant_id>`
- **Expected success**: `201` or `202`
- **Labels**: low-cardinality only (`region`, `environment`) plus required metric labels.

| Metric | Required labels |
|---|---|
| `cpu_usage_percent` | `region` |
| `memory_usage_percent` | `region` |
| `active_connections` | `region` |
| `api_latency_ms` | `region` |
| `db_connection_pool_pct` | `region`, `db_type` |
| `queue_depth` | `region`, `queue_name` |
| `cache_hit_rate_pct` | `region`, `cache_type` |

## 7. Stress diagnostics

Keep these scripts unchanged for ceiling/failure analysis only:

```bash
k6 run tests/k6/sc01_gradual_drift.js -e TELEMETRY_API_HOST=<alb-dns>
k6 run tests/k6/sc02_spike.js -e TELEMETRY_API_HOST=<alb-dns>
k6 run tests/k6/sc03_slow_leak.js -e TELEMETRY_API_HOST=<alb-dns>
k6 run tests/k6/sc04_noisy_baseline.js -e TELEMETRY_API_HOST=<alb-dns>
```

Old 2026-06-30 k6 outputs were deleted because they were stress diagnostics from a bad acceptance design. Regenerate stress only after acceptance passes.

## 8. Scope boundaries

Not faked:

- 50k events/sec is telemetry design ceiling, not capstone acceptance load.
- Cross-account tenant-role isolation is N/A unless sandbox has tenant accounts/roles.
- Training pipeline is design-only; manual baseline refresh + retrain ADR cover requirement.
- Cost Explorer same-day actuals do not prove full-month spend; Budget/circuit breaker + forecast prove capstone cost guard.
