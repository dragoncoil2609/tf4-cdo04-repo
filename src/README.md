# Source

Place platform integration code here.

Expected integration points:

- emit telemetry according to `contracts/telemetry-contract.md`
- call AI endpoint according to `contracts/ai-api-contract.md`
- implement fallback behavior for timeout/503
- write audit evidence according to `docs/03_security_design.md`

## Telemetry API - CDO-W12-015

This repo now includes a local-first Telemetry API implementation for:

```text
POST /v1/ingest
GET /health
```

The task only implements the telemetry ingress boundary. It does not query
CloudWatch or AMP, does not build `signal_window`, does not call the AI API, and
does not implement the Prediction Worker. The existing `src/mock-e2e` app remains
a separate smoke-test path.

### Why local-first

The project does not yet have real AWS telemetry data. Valid ingest requests are
therefore persisted to local JSONL storage at:

```text
local-store/telemetry.jsonl
```

The route and service code depend on a `TelemetryStorageAdapter` interface. The
current implementation is `LocalJsonlTelemetryAdapter`; `AmpTelemetryAdapter`
exists as a clear future integration point for AMP `remote_write` and currently
raises `NotImplementedError` if selected at runtime.

### Configuration

Supported environment variables:

```env
APP_NAME=telemetry-api
ENV=local
PORT=8000
MAX_INGEST_PAYLOAD_BYTES=65536
TELEMETRY_STORAGE_BACKEND=local_jsonl
LOCAL_TELEMETRY_FILE=local-store/telemetry.jsonl
LOG_LEVEL=INFO
```

Use `TELEMETRY_STORAGE_BACKEND=local_jsonl` for local runs. The `amp` backend is
a stub for future AWS work.

### Run Locally

From the repo root:

```bash
pip install -r requirements.txt
$env:PYTHONPATH="src"
uvicorn telemetry_api.main:app --host 0.0.0.0 --port 8000
```

On macOS/Linux, use:

```bash
PYTHONPATH=src uvicorn telemetry_api.main:app --host 0.0.0.0 --port 8000
```

### Run Tests

```bash
python -m pytest tests/telemetry_api
```

### Sample Curl

```bash
curl -X POST http://localhost:8000/v1/ingest \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: demo-tenant-001" \
  -H "X-Correlation-Id: local-test-001" \
  -d '{
    "ts": "2026-06-25T10:30:00Z",
    "tenant_id": "demo-tenant-001",
    "service_id": "payment-gateway",
    "metric_type": "api_latency_ms",
    "value": 450.5,
    "labels": {
      "region": "us-east-1"
    }
  }'
```

Expected success response:

```json
{
  "status": "accepted",
  "correlation_id": "local-test-001",
  "tenant_id": "demo-tenant-001",
  "service_id": "payment-gateway",
  "metric_type": "api_latency_ms"
}
```

Expected local JSONL output:

```json
{"correlation_id":"local-test-001","received_at":"2026-06-25T10:30:01Z","ts":"2026-06-25T10:30:00Z","tenant_id":"demo-tenant-001","service_id":"payment-gateway","metric_type":"api_latency_ms","value":450.5,"labels":{"region":"us-east-1"},"ingest_source":"local_api"}
```

### Headers

`X-Tenant-Id` is required and must match body `tenant_id`. This prevents a caller
from sending telemetry under another tenant by changing only the JSON payload.

`X-Correlation-Id` is optional. If omitted, the API generates a UUID. Every ingest
response and structured ingest log includes the same correlation ID.
