#!/usr/bin/env bash
set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 2
  fi
}

require API_GATEWAY_BASE_URL
require PREDICTION_QUEUE_URL
require DYNAMODB_AUDIT_TABLE

resolve_api_gateway_base_url() {
  local endpoint="${API_GATEWAY_BASE_URL}"
  case "${endpoint}" in
    http://*|https://*) printf '%s\n' "${endpoint%/}" ;;
    *) printf '%s\n' "https://${endpoint%/}" ;;
  esac
}

AWS_REGION="${AWS_REGION:-us-east-1}"
TENANT_ID="${TENANT_ID:-demo-tenant-001}"
SERVICE_ID="${SERVICE_ID:-ledger}"
SEED_MINUTES="${SEED_MINUTES:-125}"
POLL_SECONDS="${POLL_SECONDS:-600}"
BASE_URL="$(resolve_api_gateway_base_url)"
PREDICTION_ID="acceptance-$(date +%Y%m%d%H%M%S)"
INGEST_AUTH_HEADER=()
if [[ -n "${TENANT_INGEST_TOKEN:-}" ]]; then
  INGEST_AUTH_HEADER=(-H "Authorization: Bearer ${TENANT_INGEST_TOKEN}")
fi

post_metric() {
  local payload="$1"
  curl -sS -o /tmp/acceptance-ingest-response.txt -w "%{http_code}" \
    -X POST "${BASE_URL}/v1/ingest" \
    -H "Content-Type: application/json" \
    -H "X-Tenant-Id: ${TENANT_ID}" \
    -H "X-Correlation-Id: ${PREDICTION_ID}" \
    "${INGEST_AUTH_HEADER[@]}" \
    -d "${payload}"
}

echo "Seeding ${SEED_MINUTES} minutes × 7 signals for tenant=${TENANT_ID} service=${SERVICE_ID}"
for minute in $(seq 1 "${SEED_MINUTES}"); do
  while IFS= read -r payload; do
    status="$(post_metric "${payload}" || true)"
    if [[ "${status}" != "201" && "${status}" != "202" ]]; then
      echo "Ingest failed: HTTP ${status}" >&2
      cat /tmp/acceptance-ingest-response.txt >&2 || true
      exit 1
    fi
  done < <(python - "${TENANT_ID}" "${SERVICE_ID}" "${AWS_REGION}" <<'PY'
import json, sys
from datetime import datetime, timezone

tenant, service, region = sys.argv[1:4]
ts = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
metrics = [
    ("cpu_usage_percent", 42.0, {"region": region, "environment": "acceptance"}),
    ("memory_usage_percent", 55.0, {"region": region, "environment": "acceptance"}),
    ("active_connections", 120.0, {"region": region, "environment": "acceptance"}),
    ("db_connection_pool_pct", 35.0, {"region": region, "db_type": "postgres", "environment": "acceptance"}),
    ("queue_depth", 3.0, {"region": region, "queue_name": "acceptance", "environment": "acceptance"}),
    ("cache_hit_rate_pct", 91.0, {"region": region, "cache_type": "redis", "environment": "acceptance"}),
    ("api_latency_ms", 180.0, {"region": region, "environment": "acceptance"}),
]
for metric_type, value, labels in metrics:
    print(json.dumps({
        "ts": ts,
        "tenant_id": tenant,
        "service_id": service,
        "metric_type": metric_type,
        "value": value,
        "labels": labels,
    }, separators=(",", ":")))
PY
)
  if (( minute < SEED_MINUTES )); then
    sleep 60
  fi
done

echo "Waiting one scrape interval before prediction job"
sleep "${POST_SEED_SLEEP_SECONDS:-30}"

job_body="$(python - "${TENANT_ID}" "${SERVICE_ID}" "${PREDICTION_ID}" <<'PY'
import json, sys
tenant, service, prediction_id = sys.argv[1:4]
print(json.dumps({
    "tenant_id": tenant,
    "service_id": service,
    "lookback_window_minutes": 120,
    "correlation_id": prediction_id,
}))
PY
)"

aws sqs send-message \
  --region "${AWS_REGION}" \
  --queue-url "${PREDICTION_QUEUE_URL}" \
  --message-body "${job_body}" \
  >/tmp/acceptance-send-message.json

echo "Polling DynamoDB audit for complete AI decision prediction_id=${PREDICTION_ID}"
expr_values="$(mktemp)"
python - "${TENANT_ID}" "${SERVICE_ID}" "${PREDICTION_ID}" "${expr_values}" <<'PY'
import json, sys
tenant, service, prediction_id, path = sys.argv[1:5]
with open(path, "w", encoding="utf-8") as f:
    json.dump({
        ":tenant": {"S": tenant},
        ":service": {"S": service},
        ":prediction_id": {"S": prediction_id},
        ":source": {"S": "AI_ENGINE"},
        ":evidence": {"S": "complete_window"},
        ":status": {"N": "200"},
    }, f)
PY

deadline=$((SECONDS + POLL_SECONDS))
while (( SECONDS < deadline )); do
  aws dynamodb scan \
    --region "${AWS_REGION}" \
    --table-name "${DYNAMODB_AUDIT_TABLE}" \
    --filter-expression "tenant_id = :tenant AND service_id = :service AND prediction_id = :prediction_id AND prediction_source = :source AND evidence_status = :evidence AND ai_status_code = :status" \
    --expression-attribute-values "file://${expr_values}" \
    --limit 10 \
    >/tmp/acceptance-audit-scan.json

  count="$(python - <<'PY'
import json
with open('/tmp/acceptance-audit-scan.json', encoding='utf-8') as f:
    print(json.load(f).get('Count', 0))
PY
)"
  if [[ "${count}" != "0" ]]; then
    mkdir -p evidence/logs
    cp /tmp/acceptance-send-message.json evidence/logs/acceptance-ai-send-message.json
    cp /tmp/acceptance-audit-scan.json evidence/logs/acceptance-ai-audit-scan.json
    echo "Acceptance AI pipeline passed: complete_window + AI_ENGINE + ai_status_code=200"
    exit 0
  fi
  sleep 15
done

mkdir -p evidence/logs
cp /tmp/acceptance-send-message.json evidence/logs/acceptance-ai-send-message.json
cp /tmp/acceptance-audit-scan.json evidence/logs/acceptance-ai-audit-scan.json

echo "Acceptance AI pipeline failed: no complete_window AI_ENGINE audit record found" >&2
exit 1
