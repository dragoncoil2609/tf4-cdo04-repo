# Tests

Place test runners and scenarios here.

## k6 Load Test Scenarios

Run from repo root. Set `TELEMETRY_API_HOST` to the Telemetry API address:

```bash
# SC-01: Gradual Drift (ledger, 200→1500 RPS, 45 min)
k6 run tests/k6/sc01_gradual_drift.js -e TELEMETRY_API_HOST=localhost:8080

# SC-02: Sudden Spike (payment-gw, burst 4500 RPS, 2 min)
k6 run tests/k6/sc02_spike.js -e TELEMETRY_API_HOST=localhost:8080

# SC-03: Slow Leak (ledger, soak 800 RPS, 2 hours)
k6 run tests/k6/sc03_slow_leak.js -e TELEMETRY_API_HOST=localhost:8080

# SC-04: Noisy Baseline (fraud-detector, sawtooth 100→2000 RPS)
k6 run tests/k6/sc04_noisy_baseline.js -e TELEMETRY_API_HOST=localhost:8080
```

### Scenario summary

| Scenario | Script | Service | Profile | Dur. | Peak RPS | Metrics |
|---|---|---|---|---|---|---|
| SC-01 Gradual Drift | `sc01_gradual_drift.js` | ledger | ramp stages | 45m | 1,500 | api_latency_ms, cpu_usage_percent, memory_usage_percent, db_connection_pool_pct |
| SC-02 Sudden Spike | `sc02_spike.js` | payment-gw | constant-arrival | 2m | 4,500 | api_latency_ms |
| SC-03 Slow Leak | `sc03_slow_leak.js` | ledger | constant-arrival soak | 2h | 800 | memory_usage_percent, cpu_usage_percent, api_latency_ms, active_connections |
| SC-04 Noisy Baseline | `sc04_noisy_baseline.js` | fraud-detector | ramping-arrival sawtooth | ~15m | 2,000 | queue_depth, api_latency_ms, cpu_usage_percent, memory_usage_percent |

### Contract

- **Endpoint**: `POST /v1/ingest`
- **Payload**: `{ts, tenant_id, service_id, metric_type, value, labels}`
- **Headers**: `Content-Type: application/json`, `X-Tenant-Id: <tenant_id>`
- **Expected response**: `201` (accepted)
- **Labels**: low-cardinality only (`region`, `environment`) — no `request_id`, `user_id`, or other high-cardinality keys.

## TF4 Evidence Requirements

Required TF4 evidence covers at least:

- Gradual drift
- Sudden spike
- Slow leak
- Noisy baseline
- At least 3 services
- Lead time >= 15 minutes
- False-positive rate <= 12%
- Catch rate >= 80%
