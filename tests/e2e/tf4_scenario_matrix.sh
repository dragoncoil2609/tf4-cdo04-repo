#!/usr/bin/env bash
# Mentor-facing TF4 scenario matrix.
# Seeds live telemetry, triggers Worker predictions, and records AI/DynamoDB audit evidence.
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
WARMUP_MINUTES="${WARMUP_MINUTES:-120}"
SCENARIO_MINUTES="${SCENARIO_MINUTES:-60}"
POLL_SECONDS="${POLL_SECONDS:-1200}"
BASE_URL="$(resolve_api_gateway_base_url)"
INGEST_AUTH_HEADER=()
if [[ -n "${TENANT_INGEST_TOKEN:-}" ]]; then
  INGEST_AUTH_HEADER=(-H "Authorization: Bearer ${TENANT_INGEST_TOKEN}")
fi
mkdir -p evidence/logs

SCENARIOS=(
  "gradual-drift-ledger|ledger|true|30|15|gradual_drift"
  "sudden-spike-payment-gw|payment-gw|true|16|16|sudden_spike"
  "slow-leak-fraud-detector|fraud-detector|true|60|45|slow_leak"
  "noisy-baseline-fraud-detector|fraud-detector|false|0|60|noisy_baseline"
)

post_metric() {
  local payload="$1" correlation_id="$2"
  curl -sS -o /tmp/tf4-scenario-ingest-response.txt -w "%{http_code}" \
    -X POST "${BASE_URL}/v1/ingest" \
    -H "Content-Type: application/json" \
    -H "X-Tenant-Id: ${TENANT_ID}" \
    -H "X-Correlation-Id: ${correlation_id}" \
    "${INGEST_AUTH_HEADER[@]}" \
    -d "${payload}"
}

generate_payloads() {
  local service_id="$1" scenario_type="$2" scenario_minute="$3"
  python - "${TENANT_ID}" "${service_id}" "${AWS_REGION}" "${scenario_type}" "${scenario_minute}" <<'PY'
import json, sys
from datetime import datetime, timezone

tenant, service, region, scenario, minute = sys.argv[1:6]
minute = int(minute)
ts = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
values = {
    "cpu_usage_percent": 42.0,
    "memory_usage_percent": 55.0,
    "active_connections": 120.0,
    "db_connection_pool_pct": 35.0,
    "queue_depth": 3.0,
    "cache_hit_rate_pct": 91.0,
    "api_latency_ms": 180.0,
}
if scenario == "gradual_drift" and minute > 0:
    values["api_latency_ms"] = 180.0 + minute * 18
    values["db_connection_pool_pct"] = min(99.0, 35.0 + minute * 2)
elif scenario == "sudden_spike" and minute >= 15:
    values["active_connections"] = 4500.0
    values["api_latency_ms"] = 1400.0
elif scenario == "slow_leak" and minute > 0:
    values["memory_usage_percent"] = min(96.0, 55.0 + minute * 0.8)
    values["queue_depth"] = min(300.0, 3.0 + minute * 4)
elif scenario == "noisy_baseline" and minute > 0:
    values["api_latency_ms"] = 180.0 + (20 if minute % 2 == 0 else -20)
    values["cache_hit_rate_pct"] = 91.0 + (3 if minute % 3 == 0 else -3)
labels = {
    "cpu_usage_percent": {"region": region, "environment": "acceptance"},
    "memory_usage_percent": {"region": region, "environment": "acceptance"},
    "active_connections": {"region": region, "environment": "acceptance"},
    "db_connection_pool_pct": {"region": region, "db_type": "postgres", "environment": "acceptance"},
    "queue_depth": {"region": region, "queue_name": service, "environment": "acceptance"},
    "cache_hit_rate_pct": {"region": region, "cache_type": "redis", "environment": "acceptance"},
    "api_latency_ms": {"region": region, "environment": "acceptance"},
}
for metric_type, value in values.items():
    print(json.dumps({
        "ts": ts,
        "tenant_id": tenant,
        "service_id": service,
        "metric_type": metric_type,
        "value": value,
        "labels": labels[metric_type],
    }, separators=(",", ":")))
PY
}

send_prediction_job() {
  local scenario_id="$1" service_id="$2" prediction_minute="$3"
  body="$(python - "${TENANT_ID}" "${service_id}" "${scenario_id}" "${prediction_minute}" <<'PY'
import json, sys
tenant, service, scenario, minute = sys.argv[1:5]
print(json.dumps({
    "tenant_id": tenant,
    "service_id": service,
    "lookback_window_minutes": 120,
    "correlation_id": scenario,
    "scenario_minute": int(minute),
}))
PY
)"
  aws sqs send-message --region "${AWS_REGION}" --queue-url "${PREDICTION_QUEUE_URL}" --message-body "${body}" >/dev/null
}

write_ground_truth() {
  python - "${TENANT_ID}" "${WARMUP_MINUTES}" "${SCENARIO_MINUTES}" <<'PY'
import json, sys
tenant, warmup, scenario_minutes = sys.argv[1:4]
scenarios = [
    {"scenario_id": "gradual-drift-ledger", "service_id": "ledger", "expected_anomaly": True, "breach_minute": 30, "prediction_minute": 15, "expected_lead_time_minutes": 15},
    {"scenario_id": "sudden-spike-payment-gw", "service_id": "payment-gw", "expected_anomaly": True, "breach_minute": 16, "prediction_minute": 16, "expected_lead_time_minutes": 0},
    {"scenario_id": "slow-leak-fraud-detector", "service_id": "fraud-detector", "expected_anomaly": True, "breach_minute": 60, "prediction_minute": 45, "expected_lead_time_minutes": 15},
    {"scenario_id": "noisy-baseline-fraud-detector", "service_id": "fraud-detector", "expected_anomaly": False, "breach_minute": None, "prediction_minute": 60, "expected_lead_time_minutes": 0},
]
with open("evidence/logs/tf4-scenario-ground-truth.json", "w", encoding="utf-8") as f:
    json.dump({"tenant_id": tenant, "warmup_minutes": int(warmup), "scenario_minutes": int(scenario_minutes), "scenarios": scenarios}, f, indent=2)
PY
}

write_ground_truth

echo "Warmup ${WARMUP_MINUTES} minutes for complete 120-minute AMP window"
for minute in $(seq 1 "${WARMUP_MINUTES}"); do
  for entry in "${SCENARIOS[@]}"; do
    IFS='|' read -r scenario_id service_id expected breach predict scenario_type <<< "${entry}"
    while IFS= read -r payload; do
      status="$(post_metric "${payload}" "${scenario_id}" || true)"
      if [[ "${status}" != "201" && "${status}" != "202" ]]; then
        echo "Warmup ingest failed for ${scenario_id}: HTTP ${status}" >&2
        cat /tmp/tf4-scenario-ingest-response.txt >&2 || true
        exit 1
      fi
    done < <(generate_payloads "${service_id}" "normal" "0")
  done
  sleep 60
done

echo "Scenario phase ${SCENARIO_MINUTES} minutes"
for minute in $(seq 1 "${SCENARIO_MINUTES}"); do
  for entry in "${SCENARIOS[@]}"; do
    IFS='|' read -r scenario_id service_id expected breach predict scenario_type <<< "${entry}"
    while IFS= read -r payload; do
      status="$(post_metric "${payload}" "${scenario_id}" || true)"
      if [[ "${status}" != "201" && "${status}" != "202" ]]; then
        echo "Scenario ingest failed for ${scenario_id}: HTTP ${status}" >&2
        cat /tmp/tf4-scenario-ingest-response.txt >&2 || true
        exit 1
      fi
    done < <(generate_payloads "${service_id}" "${scenario_type}" "${minute}")
    if [[ "${minute}" == "${predict}" ]]; then
      sleep "${POST_SEED_SLEEP_SECONDS:-30}"
      send_prediction_job "${scenario_id}" "${service_id}" "${minute}"
    fi
  done
  if (( minute < SCENARIO_MINUTES )); then
    sleep 60
  fi
done

expr_values="$(mktemp)"
python - "${TENANT_ID}" "${expr_values}" <<'PY'
import json, sys
tenant, path = sys.argv[1:3]
with open(path, "w", encoding="utf-8") as f:
    json.dump({":tenant": {"S": tenant}, ":source": {"S": "AI_ENGINE"}, ":evidence": {"S": "complete_window"}, ":status": {"N": "200"}}, f)
PY

deadline=$((SECONDS + POLL_SECONDS))
while (( SECONDS < deadline )); do
  aws dynamodb scan \
    --region "${AWS_REGION}" \
    --table-name "${DYNAMODB_AUDIT_TABLE}" \
    --filter-expression "tenant_id = :tenant AND prediction_source = :source AND evidence_status = :evidence AND ai_status_code = :status" \
    --expression-attribute-values "file://${expr_values}" \
    --limit 100 \
    > evidence/logs/tf4-scenario-audit-scan.json

  count="$(python - <<'PY'
import json
with open('evidence/logs/tf4-scenario-audit-scan.json', encoding='utf-8') as f:
    data = json.load(f)
ids = {item.get('prediction_id', {}).get('S') for item in data.get('Items', [])}
needed = {'gradual-drift-ledger', 'sudden-spike-payment-gw', 'slow-leak-fraud-detector', 'noisy-baseline-fraud-detector'}
print(len(ids & needed))
PY
)"
  if [[ "${count}" == "4" ]]; then
    break
  fi
  sleep 15
done

python tests/e2e/eval_report.py || true
python - <<'PY'
import json
from pathlib import Path
scan = json.loads(Path('evidence/logs/tf4-scenario-audit-scan.json').read_text(encoding='utf-8')) if Path('evidence/logs/tf4-scenario-audit-scan.json').exists() else {"Items": []}
summary = {
    "audit_items": scan.get("Count", len(scan.get("Items", []))),
    "required_scenarios": 4,
    "note": "Final pass/fail is in evidence/logs/eval-report.json",
}
Path('evidence/logs/tf4-scenario-summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
print(json.dumps(summary, indent=2))
PY
