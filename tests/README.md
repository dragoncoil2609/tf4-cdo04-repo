# Tests

Testing is acceptance-first. Stress scripts are diagnostic only; they never prove final acceptance by themselves.

## 1. Final live status

Current final evidence set is accepted for capstone demo / mentor review with one visible caveat.

```text
2m 50 RPS smoke: strict pass, 0 failures, 0 dropped iterations.
3h 50 RPS run: accepted pass by project owner, p95 257 ms, 1 failed request, 5 dropped iterations over ~540k requests.
AI path: DynamoDB audit contains AI_ENGINE + complete_window + ai_status_code=200 for ledger, payment-gw, fraud-detector.
```

Do not overclaim:

```text
3h run is not a strict zero-drop k6 pass.
50 RPS is ingest API headroom, not AMP sample persistence rate.
```

Evidence summary:

```text
evidence/logs/acceptance-50rps-2m-final-summary.json
evidence/logs/acceptance-50rps-3h-final-summary.json
evidence/logs/prediction-worker-recent.json
evidence/logs/ai-engine-recent.json
evidence/logs/audit-recent-scan.json
```

## 2. Runtime env

Use API Gateway public endpoint for final evidence. When running in AWS (with credentials), SigV4 signing is automatic; the k6 script uses the jslib SignatureV4 module and curl-based scripts use `--aws-sigv4`. The ingest token is passed through `X-Tenant-Ingest-Token` header when signed, or `Authorization: Bearer` when unsigned.

```bash
export AWS_REGION=us-east-1
export API_GATEWAY_BASE_URL="$(terraform -chdir=infra/terraform output -raw api_gateway_base_url)"
export TELEMETRY_API_HOST="$API_GATEWAY_BASE_URL"
export TENANT_ID=demo-tenant-001
export SERVICE_IDS=ledger,payment-gw,fraud-detector
export TENANT_INGEST_TOKEN="$(terraform -chdir=infra/terraform output -raw tenant_ingest_token)"  # Terraform-managed demo token; stored in Terraform state
export AI_API_GATEWAY_ENDPOINT="$(terraform -chdir=infra/terraform output -raw ai_api_gateway_endpoint)"
```

ALB is internal after migration; do not use raw ALB DNS for public tests.

## 3. Unit/contract gate

```bash
PYTHONPATH=src/ai_engine:src pytest -q
```

Last known full local result:

```text
155 passed, 1 warning
```

## 4. Deploy smoke gate

```bash
bash scripts/post_apply_smoke.sh
```

Expected:

```text
/health returns 200 over custom HTTPS domain
/v1/ingest returns 201 or 202
/metrics is not public via ALB
unsigned API Gateway /v1/predict returns 403
signed API Gateway /v1/predict returns 200/201/202 when curl SigV4 credentials are available
API Gateway /metrics remains blocked (403/404)
ECS services desired/running stable
SQS/DLQ no unsafe growth
```

## 5. Low-RPS ingest acceptance

### 5.1 2m smoke

```bash
k6 run tests/k6/acceptance_ingest.js \
  -e TELEMETRY_API_HOST=https://xbrain26hackathon269.software \
  -e TENANT_ID=demo-tenant-001 \
  -e SERVICE_IDS=ledger,payment-gw,fraud-detector \
  -e TENANT_INGEST_TOKEN="$TENANT_INGEST_TOKEN" \
  -e RATE=50 \
  -e DURATION=2m \
  -e AWS_REGION=us-east-1 \
  --summary-export evidence/logs/acceptance-50rps-2m-final-summary.json
```

Note: When `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables are set, the k6 script automatically switches to SigV4 signing with service `execute-api`, sending the tenant token through `X-Tenant-Ingest-Token` header instead of `Authorization: Bearer`. The same environment variables (`TELEMETRY_API_HOST`, `TENANT_ID`, `TENANT_INGEST_TOKEN`, `RATE`, `DURATION`) remain unchanged.

Observed:

```text
http_reqs: 6,001
rate: 49.910/s
p95 latency: 246.51 ms
failed requests: 0
dropped_iterations: 0
checks: 6,001 / 6,001
```

### 5.2 3h final run

```bash
k6 run tests/k6/acceptance_ingest.js \
  -e TELEMETRY_API_HOST=https://xbrain26hackathon269.software \
  -e TENANT_ID=demo-tenant-001 \
  -e SERVICE_IDS=ledger,payment-gw,fraud-detector \
  -e TENANT_INGEST_TOKEN="$TENANT_INGEST_TOKEN" \
  -e RATE=50 \
  -e DURATION=3h \
  -e AWS_REGION=us-east-1 \
  --summary-export evidence/logs/acceptance-50rps-3h-final-summary.json
```

Observed:

```text
http_reqs: 539,995
rate: 49.9986/s
p95 latency: 257.42 ms
failed requests: 1 / 539,995 = 0.000185%
dropped_iterations: 5 / ~540,000 = 0.00093%
checks: 539,994 / 539,995 = 99.9998%
```

Interpretation:

```text
Operationally accepted as pass for demo.
Strict zero-drop k6 threshold failed; caveat stays documented.
```

## 6. Telemetry ingest semantics

Current path:

```text
producer/k6/service -> POST /v1/ingest
telemetry-api validates payload and updates Prometheus Gauge
ADOT sidecar scrapes localhost:8080/metrics every 15s
ADOT remote_writes scraped samples to AMP
prediction-worker query_range reads AMP
```

Normal prediction cadence:

```text
3 services x 7 signals / 60s = 0.35 RPS
```

So:

```text
50 RPS validates ingest API headroom.
It does not prove AMP stores 50 event samples/sec.
Gauge + ADOT scrape is valid for 1-minute prediction buckets.
```

## 7. AI path verification

Required audit fields:

```text
prediction_source = AI_ENGINE
evidence_status = complete_window
ai_status_code = 200
```

Current audit evidence has complete-window AI records for:

```text
ledger
payment-gw
fraud-detector
```

Latest good records are documented in `docs/07_test_eval_report.md`.

## 8. Ingest contract

- **Endpoint**: `POST /v1/ingest`
- **Payload**: `{ts, tenant_id, service_id, metric_type, value, labels}`
- **Headers**: `Content-Type: application/json`, `X-Tenant-Id: <tenant_id>`
- **Auth**: `AWS_IAM`/SigV4 enforced by API Gateway with service `execute-api`. Unsigned requests return `403`. Bearer fallback (`Authorization: Bearer <token>`) used only when AWS credentials are absent (local dev).
- **Tenant token**: Passed via `X-Tenant-Ingest-Token` header in SigV4 mode; the signed request does not use the `Authorization` header for the ingest token.
- **Expected success**: `201` or `202`

### 8.1 SigV4 ingest usage

k6 (automatic when `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set):

```bash
k6 run tests/k6/acceptance_ingest.js \
  -e TELEMETRY_API_HOST=https://api.example.com \
  -e TENANT_ID=demo-tenant-001 \
  -e SERVICE_IDS=ledger,payment-gw,fraud-detector \
  -e TENANT_INGEST_TOKEN="$TENANT_INGEST_TOKEN" \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -e AWS_REGION=us-east-1 \
  -e RATE=50 \
  -e DURATION=2m
```

curl (use `--aws-sigv4` flag, available in curl 7.75+):

```bash
curl -X POST "${API_GATEWAY_BASE_URL}/v1/ingest" \
  --aws-sigv4 "aws:amz:${AWS_REGION}:execute-api" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Tenant-Ingest-Token: ${TENANT_INGEST_TOKEN}" \
  -d '{"ts":"...","tenant_id":"demo-tenant-001","service_id":"ledger","metric_type":"cpu_usage_percent","value":42,"labels":{"region":"us-east-1"}}'
```

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


## 9. Scope boundaries

Not faked:

- 50k events/sec is design ceiling, not capstone acceptance load.
- Cross-account tenant-role isolation is N/A unless sandbox has tenant accounts/roles.
- Training pipeline is design-only; manual baseline refresh + retrain ADR cover requirement.
- Cost Explorer same-day actuals do not prove full-month spend; Budget/circuit breaker + forecast prove capstone cost guard.
