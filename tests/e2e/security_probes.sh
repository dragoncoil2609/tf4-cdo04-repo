#!/usr/bin/env bash
# Safe E2E security probes for public metrics exposure and tenant/input isolation.
# Writes evidence only; does not perform destructive or privileged testing.
set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 2
  fi
}

require ALB_DNS_NAME

resolve_alb_base_url() {
  local endpoint="${ALB_BASE_URL:-${ALB_DNS_NAME}}"
  case "${endpoint}" in
    http://*|https://*) printf '%s\n' "${endpoint%/}" ;;
    *) printf '%s\n' "${ALB_SCHEME:-http}://${endpoint%/}" ;;
  esac
}

AWS_REGION="${AWS_REGION:-us-east-1}"
BASE_URL="$(resolve_alb_base_url)"
OUT="${OUT:-evidence/logs/security-probes.json}"
mkdir -p "$(dirname "${OUT}")"

json_escape() {
  python -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

probe_metric() {
  local metric_type="${1:-api_latency_ms}"
  local tenant="${2:-tenant-a}"
  python - "${metric_type}" "${tenant}" "${AWS_REGION}" <<'PY'
import json, sys
metric, tenant, region = sys.argv[1:4]
labels = {"region": region, "environment": "security"}
if metric == "db_connection_pool_pct":
    labels["db_type"] = "postgres"
elif metric == "queue_depth":
    labels["queue_name"] = "security"
elif metric == "cache_hit_rate_pct":
    labels["cache_type"] = "redis"
print(json.dumps({
    "ts": "2026-06-30T00:00:00Z",
    "tenant_id": tenant,
    "service_id": "security-probe",
    "metric_type": metric,
    "value": 1,
    "labels": labels,
}, separators=(",", ":")))
PY
}

run_probe() {
  local name="$1" expected="$2" method="$3" path="$4" body="${5:-}" tenant_header="${6:-}" auth_mode="${7:-valid}"
  local tmp_body tmp_status status passed response
  tmp_body="$(mktemp)"
  tmp_status="$(mktemp)"

  args=(-sS -o "${tmp_body}" -w "%{http_code}" -X "${method}" "${BASE_URL}${path}")
  if [[ -n "${tenant_header}" ]]; then
    args+=(-H "X-Tenant-Id: ${tenant_header}")
  fi
  if [[ -n "${TENANT_INGEST_TOKEN:-}" && "${auth_mode}" == "valid" ]]; then
    args+=(-H "Authorization: Bearer ${TENANT_INGEST_TOKEN}")
  elif [[ "${auth_mode}" == "invalid" ]]; then
    args+=(-H "Authorization: Bearer invalid-token")
  fi
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" -d "${body}")
  fi

  status="$(curl "${args[@]}" || true)"
  response="$(cat "${tmp_body}" | json_escape)"
  rm -f "${tmp_body}" "${tmp_status}"

  case "${expected}" in
    not_200) [[ "${status}" != "200" ]] && passed=true || passed=false ;;
    400) [[ "${status}" == "400" ]] && passed=true || passed=false ;;
    400_or_422) [[ "${status}" == "400" || "${status}" == "422" ]] && passed=true || passed=false ;;
    reject) [[ "${status}" != "200" && "${status}" != "201" && "${status}" != "202" ]] && passed=true || passed=false ;;
    *) passed=false ;;
  esac

  printf '{"name":"%s","expected":"%s","actual_status":%s,"pass":%s,"response":%s}' \
    "${name}" "${expected}" "${status:-0}" "${passed}" "${response}"
}

missing_tenant_body="$(probe_metric api_latency_ms tenant-a)"
mismatch_body="$(probe_metric api_latency_ms tenant-b)"
missing_field_body="$(python - <<'PY'
import json
print(json.dumps({"ts":"2026-06-30T00:00:00Z","tenant_id":"tenant-a","service_id":"security-probe","value":1,"labels":{"region":"us-east-1"}}, separators=(",", ":")))
PY
)"
pii_body="$(python - <<'PY'
import json
print(json.dumps({"ts":"2026-06-30T00:00:00Z","tenant_id":"tenant-a","service_id":"security-probe","metric_type":"api_latency_ms","value":1,"labels":{"region":"us-east-1","user_id":"u-123"}}, separators=(",", ":")))
PY
)"

{
  printf '{"generated_at":"%s","base_url":"%s","probes":[' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BASE_URL}"
  run_probe "public_metrics_blocked" "not_200" "GET" "/metrics"
  if [[ -n "${TENANT_INGEST_TOKEN:-}" ]]; then
    printf ','
    run_probe "missing_auth_token" "reject" "POST" "/v1/ingest" "${missing_tenant_body}" "tenant-a" "none"
    printf ','
    run_probe "invalid_auth_token" "reject" "POST" "/v1/ingest" "${missing_tenant_body}" "tenant-a" "invalid"
  fi
  printf ','
  run_probe "missing_tenant_header" "reject" "POST" "/v1/ingest" "${missing_tenant_body}"
  printf ','
  run_probe "tenant_header_body_mismatch" "400" "POST" "/v1/ingest" "${mismatch_body}" "tenant-a"
  printf ','
  run_probe "missing_metric_type" "400_or_422" "POST" "/v1/ingest" "${missing_field_body}" "tenant-a"
  printf ','
  run_probe "pii_label_rejected" "400_or_422" "POST" "/v1/ingest" "${pii_body}" "tenant-a"
  printf '],"n_a":["cross-account STS tenant-role isolation: no multi-account sandbox roles deployed","IAM privilege escalation pentest: outside safe capstone acceptance scope"]}'
} > "${OUT}"

python - "${OUT}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
failed = [p for p in data["probes"] if not p["pass"]]
print(json.dumps({"security_probes": "pass" if not failed else "fail", "failed": failed}, indent=2))
raise SystemExit(1 if failed else 0)
PY
