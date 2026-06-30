# Test & Eval Report - Task force 4 · CDO Foresight Lens

<!-- Doc owner: Nhóm CDO / QA Lead
     Status: REDESIGNED from mentor template - pending acceptance rerun
     Region: us-east-1
     Environment: sandbox
     Date updated: 2026-06-30 -->

> **Design reset:** previous k6-heavy evidence was deleted and no longer represents current acceptance evidence. Runtime artifacts are generated on demand under `evidence/logs/`, which is intentionally not ignored so the final evidence pack can be committed. Final acceptance must be rerun from this design.

## 1. Test coverage

| Requirement | Tool / command | Evidence |
|---|---|---|
| Unit + contract behavior | `PYTHONPATH=src/ai_engine:src pytest -q` | CI/local pytest output |
| Deploy smoke | `bash scripts/post_apply_smoke.sh` | `evidence/logs/final-smoke.log` |
| Complete Worker → AMP → AI → audit path | `bash tests/e2e/tf4_scenario_matrix.sh`; optional legacy single-service proof with `RUN_SINGLE_PIPELINE=1 bash tests/e2e/run_final_acceptance.sh` | `tf4-scenario-audit-scan.json`; optional `acceptance-ai-audit-scan.json` |
| 4 TF4 scenarios | `bash tests/e2e/tf4_scenario_matrix.sh` | `tf4-scenario-summary.json`, `tf4-scenario-audit-scan.json` |
| Precision/recall/F1/confusion matrix/Brier | `python tests/e2e/eval_report.py` | `eval-report.json`, `eval-report.md` |
| Low-RPS load | `k6 run tests/k6/acceptance_ingest.js` at 50/100 RPS | `acceptance-50rps-summary.json`, `acceptance-100rps-summary.json` |
| Security + tenant isolation probes | `bash tests/e2e/security_probes.sh` | `security-probes.json` |
| Cost guard | Budget + Cost Explorer collection | `budget-final.json`, `cost-explorer-final.json` |
| Curveballs/failure analysis | manual write-up | `evidence/curveball-responses.md` |

Primary command:

```bash
bash tests/e2e/run_final_acceptance.sh
```

## 2. SLO and TF4 evidence

| Gate | Target | Source | Current status |
|---|---|---|---|
| API availability | ≥ 99.5% demo-quality | smoke + k6 summaries | pending rerun |
| API latency | p95 < 1000ms at 50/100 RPS | k6 summaries | pending rerun |
| Error rate | < 1% | k6 summaries | pending rerun |
| AI Engine SLA | P99 < 500ms / 100 RPS by contract; CDO proves integrated call succeeds | audit `ai_latency_ms`, AI health | pending rerun |
| Complete AI path | `AI_ENGINE` + `complete_window` + `ai_status_code=200` | DynamoDB audit scan | pending rerun |
| 3+ services | `ledger`, `payment-gw`, `fraud-detector` | scenario ground truth + audit scan | pending rerun |
| 4 real scenarios | gradual drift, sudden spike, slow leak, noisy baseline | scenario matrix | pending rerun |
| Lead time | ≥15 min before breach on at least one ≥2h window | scenario ground truth + eval report | pending rerun |
| Catch rate | ≥80% | eval report | pending rerun |
| FP rate | ≤12% | eval report | pending rerun |
| Calibration | Brier score or reliability bins | eval report | pending rerun |
| Recommendation contract | action verb + target + from→to + confidence + evidence link | audit scan / eval report | pending rerun |
| Audit | every prediction call, required fields, retention/encryption documented | DynamoDB audit + infra docs | pending rerun |
| Fail-open fallback | static threshold fallback when AI unavailable / data gap too large | worker tests + curveball evidence | pending rerun |
| Cost | budget/circuit breaker under $200 | budget/cost evidence | pending rerun |

## 3. Load test results

### 3.1 Acceptance load

Acceptance load is intentionally boring and runs only after AI correctness passes:

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

| Metric | Target | Achieved |
|---|---|---|
| RPS sustained | 50 then 100 | pending rerun |
| p95 latency | < 1000ms | pending rerun |
| Error rate | < 1% | pending rerun |
| Dropped iterations | 0 | pending rerun |
| Queue/DLQ safety | DLQ no growth | pending rerun |

### 3.2 Stress diagnostics

Existing high-RPS k6 scripts are retained for ceiling discovery only:

- `tests/k6/sc01_gradual_drift.js`
- `tests/k6/sc02_spike.js`
- `tests/k6/sc03_slow_leak.js`
- `tests/k6/sc04_noisy_baseline.js`

Old 2026-06-30 stress outputs were deleted and must not be used as final acceptance evidence.

## 4. Security test

### 4.1 Safe probes

`tests/e2e/security_probes.sh` records:

| Probe | Expected |
|---|---|
| Public `/metrics` | 403/404 or any non-200 |
| Missing tenant header | rejected |
| Header/body tenant mismatch | 400 |
| Missing metric field | 400/422 |
| PII/high-cardinality label | 400/422 |

Output: `evidence/logs/security-probes.json`.

### 4.2 Vulnerability scan

- **Gitleaks**: configured in CI with `.gitleaks.toml` narrow SigV4 curl allowlist.
- **Trivy**: configured in CI for container image scan.
- **Pass rule**: 0 CRITICAL findings; HIGH findings need mitigation notes.
- **Current artifact**: pending current CI run.

## 5. Multi-tenant isolation test

| Test | Method | Status |
|---|---|---|
| Tenant header/body mismatch | `/v1/ingest` negative probe | pending rerun |
| AI datapoint tenant mismatch | unit test in `src/ai_engine/tests/test_api.py` | covered locally/CI |
| Cross-tenant queue contamination | mismatched synthetic job + audit inspection | pending / safe sandbox probe |
| Cross-account tenant role isolation | STS assume-role between tenant accounts | N/A unless sandbox has tenant accounts/roles |
| DB row-level security | tenant-scoped table/read API | N/A: no read API for tenant data in CDO-04 sandbox |

Any real tenant leak = SEV1. N/A items must stay documented, not silently marked pass.

## 6. Failure analysis

| # | Failure | Root cause | Fix | Status |
|---|---|---|---|---|
| 1 | Telemetry API rollback on task def `:11` | ADOT v0.40.0 rejected unsupported `sending_queue` config | Removed unsupported key; ADOT config simplified | fixed |
| 2 | Gitleaks `curl-auth-user` failure | False positive on SigV4 env-var curl credentials | Added narrow `.gitleaks.toml` allowlist | fixed |
| 3 | SQS age baseline failed | `ApproximateAgeOfOldestMessage` is CloudWatch metric, not SQS attribute | Use SQS attrs for depth and CloudWatch metric for age | fixed |
| 4 | Prior k6 evidence was not acceptance-grade | Stress targets ran before correctness proof | Deleted runtime artifacts; redesigned acceptance-first tests | fixed |
| 5 | Full final evidence missing | New test design not rerun yet | Run `tests/e2e/run_final_acceptance.sh` | pending |

## 7. Final gate verdict

| Gate group | Required artifact | Current status |
|---|---|---|
| Contract/unit | pytest output / CI artifact | pending rerun |
| Smoke | `evidence/logs/final-smoke.log` | pending rerun |
| AI complete-window path | `evidence/logs/acceptance-ai-audit-scan.json` | pending rerun |
| TF4 scenario matrix | `evidence/logs/tf4-scenario-summary.json` | pending rerun |
| Eval metrics | `evidence/logs/eval-report.json`, `evidence/logs/eval-report.md` | pending rerun |
| Load acceptance | `acceptance-50rps-summary.json`, `acceptance-100rps-summary.json` | pending rerun |
| Security/isolation | `security-probes.json` | pending rerun |
| Cost | `budget-final.json`, `cost-explorer-final.json` | pending rerun |

**Final status:** redesigned and cleaned. No current runtime evidence is committed. Do not claim acceptance until regenerated evidence passes the gates above.

## Related documents

- [`02_infra_design.md`](02_infra_design.md)
- [`03_security_design.md`](03_security_design.md)
- [`05_cost_analysis.md`](05_cost_analysis.md)
- [`../tests/README.md`](../tests/README.md)
- [`../evidence/README.md`](../evidence/README.md)
