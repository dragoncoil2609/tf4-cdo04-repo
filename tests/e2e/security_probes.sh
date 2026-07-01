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

require API_GATEWAY_BASE_URL

resolve_api_gateway_base_url() {
  local endpoint="${API_GATEWAY_BASE_URL}"
  case "${endpoint}" in
    http://*|https://*) printf '%s\n' "${endpoint%/}" ;;
    *) printf '%s\n' "https://${endpoint%/}" ;;
  esac
}

AWS_REGION="${AWS_REGION:-us-east-1}"
BASE_URL="$(resolve_api_gateway_base_url)"
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
  local name="$1" expected="$2" method="$3" path="$4" body="${5:-}" tenant_header="${6:-}" auth_mode="${7:-valid}" base_url="${8:-${BASE_URL}}"
  local tmp_body status passed response
  tmp_body="$(mktemp)"

  # Determine if SigV4 should be used for this probe.
  # Auth modes: valid = apply SigV4 when AWS creds exist, else Bearer.
  #             none   = no auth header at all (for unsigned-403 probes).
  #             invalid = supply an invalid Bearer token.
  local use_sigv4=false
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" && "${auth_mode}" == "valid" ]]; then
    use_sigv4=true
  fi

  args=(-sS -o "${tmp_body}" -w "%{http_code}" -X "${method}" "${base_url}${path}")

  if [[ -n "${tenant_header}" ]]; then
    args+=(-H "X-Tenant-Id: ${tenant_header}")
  fi
  if ${use_sigv4}; then
    args+=(--aws-sigv4 "aws:amz:${AWS_REGION}:execute-api" --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}")
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
      args+=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
    fi
    if [[ -n "${TENANT_INGEST_TOKEN:-}" ]]; then
      args+=(-H "X-Tenant-Ingest-Token: ${TENANT_INGEST_TOKEN}")
    fi
  elif [[ -n "${TENANT_INGEST_TOKEN:-}" && "${auth_mode}" == "valid" && ! "${use_sigv4}" ]]; then
    args+=(-H "Authorization: Bearer ${TENANT_INGEST_TOKEN}")
  elif [[ "${auth_mode}" == "invalid" ]]; then
    args+=(-H "Authorization: Bearer invalid-token")
  fi
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" -d "${body}")
  fi

  status="$(curl "${args[@]}" || true)"
  response="$(cat "${tmp_body}" | json_escape)"
  rm -f "${tmp_body}"

  case "${expected}" in
    403) [[ "${status}" == "403" ]] && passed=true || passed=false ;;
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
  printf ','
  run_probe "unsigned_predict_requires_iam" "403" "POST" "/v1/predict" '{"signal_window":[],"context":{"deployment_version":"security","time_range":{"start_ts":"2026-06-30T00:00:00Z","end_ts":"2026-06-30T02:00:00Z"}}}'
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    # SigV4 enforced: unsigned ingest should be rejected with 403.
    printf ','
    run_probe "unsigned_ingest_requires_sigv4" "403" "POST" "/v1/ingest" "${missing_tenant_body}" "tenant-a" "none"
  elif [[ -n "${TENANT_INGEST_TOKEN:-}" ]]; then
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
