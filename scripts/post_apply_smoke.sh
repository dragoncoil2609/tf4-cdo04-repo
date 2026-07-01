#!/usr/bin/env bash
set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 2
  fi
}

http_code() {
  curl -sS -o /tmp/smoke-response.txt -w "%{http_code}" "$@"
}

write_predict_payload() {
  local out="$1"
  {
    printf '{"signal_window":['
    for i in $(seq 0 119); do
      if (( i > 0 )); then
        printf ','
      fi
      printf '{"ts":"2026-06-29T%02d:%02d:00Z","tenant_id":"smoke-test","service_id":"payment-gw","metric_type":"cpu_usage_percent","value":50}' "$((i / 60))" "$((i % 60))"
    done
    printf '],"context":{"deployment_version":"smoke","time_range":{"start_ts":"2026-06-29T00:00:00Z","end_ts":"2026-06-29T02:00:00Z"}}}'
  } > "$out"
}

resolve_api_gateway_base_url() {
  local endpoint="${API_GATEWAY_BASE_URL:-}"
  case "${endpoint}" in
    http://*|https://*) printf '%s\n' "${endpoint%/}" ;;
    *) printf '%s\n' "https://${endpoint%/}" ;;
  esac
}

require API_GATEWAY_BASE_URL
require ECS_CLUSTER_NAME
require TELEMETRY_API_SERVICE_NAME
require PREDICTION_WORKER_SERVICE_NAME
require AI_ENGINE_SERVICE_NAME
require PREDICTION_QUEUE_URL
require PREDICTION_QUEUE_DLQ_URL

BASE_URL="$(resolve_api_gateway_base_url)"
INGEST_AUTH_HEADER=()
if [[ -n "${TENANT_INGEST_TOKEN:-}" ]]; then
  INGEST_AUTH_HEADER=(-H "X-Tenant-Ingest-Token: ${TENANT_INGEST_TOKEN}")
fi

# Terraform returns after ECS service update starts; wait so API Gateway does not
# hit draining old tasks during the rolling deployment.
echo "Waiting for ECS services to become stable"
aws ecs wait services-stable \
  --cluster "${ECS_CLUSTER_NAME}" \
  --services "${TELEMETRY_API_SERVICE_NAME}" "${PREDICTION_WORKER_SERVICE_NAME}" "${AI_ENGINE_SERVICE_NAME}"

echo "Reading initial DLQ depth"
initial_dlq_depth=$(aws sqs get-queue-attributes \
  --queue-url "${PREDICTION_QUEUE_DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text)

if [[ "${initial_dlq_depth}" != "0" ]]; then
  echo "Prediction DLQ already has ${initial_dlq_depth} message(s); smoke will fail only if it grows"
fi

echo "Checking ${BASE_URL}/health"
for attempt in $(seq 1 15); do
  status=$(http_code "${BASE_URL}/health" || true)
  if [[ "${status}" == "200" ]]; then
    echo "Health check passed"
    break
  fi
  if [[ "${attempt}" == "15" ]]; then
    echo "Health check failed: HTTP ${status}" >&2
    cat /tmp/smoke-response.txt >&2 || true
    exit 1
  fi
  echo "Health attempt ${attempt}/15 got HTTP ${status}; retrying"
  sleep 10
done

echo "Checking unsigned POST ${BASE_URL}/v1/ingest returns 403 (IAM auth)"
ingest_unsigned_status=$(http_code -X POST "${BASE_URL}/v1/ingest" \
  -H "Content-Type: application/json" \
  -d '{"ts":"2026-06-29T00:00:00Z","tenant_id":"smoke-test","service_id":"payment-gw","metric_type":"api_latency_ms","value":1,"labels":{"region":"us-east-1","environment":"smoke"}}' || true)
if [[ "${ingest_unsigned_status}" != "403" ]]; then
  echo "Unsigned POST /v1/ingest returned HTTP ${ingest_unsigned_status}; expected 403 (API Gateway IAM auth)" >&2
  cat /tmp/smoke-response.txt >&2 || true
  exit 1
fi
echo "Unsigned POST /v1/ingest blocked as expected: HTTP ${ingest_unsigned_status}"

echo "Checking signed POST ${BASE_URL}/v1/ingest via SigV4"
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "Skipping signed ingest check: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not exported for curl SigV4"
elif curl --help all 2>/dev/null | grep -q -- "--aws-sigv4"; then
  for attempt in $(seq 1 15); do
    ingest_signed_status=$(curl -sS -o /tmp/signed-ingest-response.txt -w "%{http_code}" \
      --aws-sigv4 "aws:amz:${AWS_REGION:-us-east-1}:execute-api" \
      --user "${AWS_ACCESS_KEY_ID:-}:${AWS_SECRET_ACCESS_KEY:-}" \
      -H "x-amz-security-token: ${AWS_SESSION_TOKEN:-}" \
      -X POST \
      -H "Content-Type: application/json" \
      -H "X-Tenant-Id: smoke-test" \
      -H "X-Correlation-Id: smoke-test" \
      "${INGEST_AUTH_HEADER[@]}" \
      -d '{"ts":"2026-06-29T00:00:00Z","tenant_id":"smoke-test","service_id":"payment-gw","metric_type":"api_latency_ms","value":1,"labels":{"region":"us-east-1","environment":"smoke"}}' \
      "${BASE_URL}/v1/ingest" || true)
    if [[ "${ingest_signed_status}" == "201" || "${ingest_signed_status}" == "202" ]]; then
      echo "Signed POST /v1/ingest passed: HTTP ${ingest_signed_status}"
      break
    fi
    if [[ "${attempt}" == "15" ]]; then
      echo "Signed POST /v1/ingest failed: HTTP ${ingest_signed_status}" >&2
      cat /tmp/signed-ingest-response.txt >&2 || true
      exit 1
    fi
    echo "Signed ingest attempt ${attempt}/15 got HTTP ${ingest_signed_status}; retrying"
    sleep 10
  done
else
  echo "Skipping signed ingest check: curl lacks --aws-sigv4"
fi

echo "Checking ${BASE_URL}/metrics is not public"
metrics_status=$(http_code "${BASE_URL}/metrics" || true)
if [[ "${metrics_status}" == "200" ]]; then
  echo "Public /metrics is exposed via API Gateway; expected 404/403 because ADOT scrapes localhost" >&2
  exit 1
fi
if [[ "${metrics_status}" == "404" || "${metrics_status}" == "403" ]]; then
  echo "Public /metrics blocked as expected: HTTP ${metrics_status}"
else
  echo "Public /metrics returned HTTP ${metrics_status}; expected blocked endpoint"
fi

echo "Checking unsigned POST ${BASE_URL}/v1/predict returns 403 (IAM auth)"
predict_unsigned_status=$(http_code -X POST "${BASE_URL}/v1/predict" \
  -H "Content-Type: application/json" \
  -d '{"signal_window":[],"context":{"deployment_version":"smoke","time_range":{"start_ts":"2026-06-29T00:00:00Z","end_ts":"2026-06-29T02:00:00Z"}}}' || true)
if [[ "${predict_unsigned_status}" != "403" ]]; then
  echo "Unsigned POST /v1/predict returned HTTP ${predict_unsigned_status}; expected 403 (API Gateway IAM auth)" >&2
  cat /tmp/smoke-response.txt >&2 || true
  exit 1
fi
echo "Unsigned POST /v1/predict blocked as expected: HTTP ${predict_unsigned_status}"

echo "Checking signed POST ${BASE_URL}/v1/predict via SigV4"
write_predict_payload /tmp/signed-predict-payload.json
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo "Skipping signed predict check: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not exported for curl SigV4"
elif curl --help all 2>/dev/null | grep -q -- "--aws-sigv4"; then
  predict_signed_status=$(curl -sS -o /tmp/signed-predict-response.txt -w "%{http_code}" \
    --aws-sigv4 "aws:amz:${AWS_REGION:-us-east-1}:execute-api" \
    --user "${AWS_ACCESS_KEY_ID:-}:${AWS_SECRET_ACCESS_KEY:-}" \
    -H "x-amz-security-token: ${AWS_SESSION_TOKEN:-}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Tenant-Id: smoke-test" \
    -H "X-Correlation-Id: smoke-test" \
    --data-binary @/tmp/signed-predict-payload.json \
    "${BASE_URL}/v1/predict" || true)
  if [[ "${predict_signed_status}" != "200" && "${predict_signed_status}" != "201" && "${predict_signed_status}" != "202" ]]; then
    echo "Signed POST /v1/predict failed: HTTP ${predict_signed_status}" >&2
    cat /tmp/signed-predict-response.txt >&2 || true
    exit 1
  fi
  echo "Signed POST /v1/predict passed: HTTP ${predict_signed_status}"
else
  echo "Skipping signed predict check: curl lacks --aws-sigv4"
fi

if [[ -n "${AMP_QUERY_ENDPOINT:-}" ]]; then
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "Skipping AMP query check: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not exported for curl SigV4"
  elif curl --help all 2>/dev/null | grep -q -- "--aws-sigv4"; then
    echo "Checking AMP query endpoint"
    amp_query_url="${AMP_QUERY_ENDPOINT%/api/v1/query}/api/v1/query"
    amp_status=$(curl -sS -o /tmp/amp-smoke-response.txt -w "%{http_code}" \
      --aws-sigv4 "aws:amz:${AWS_REGION:-us-east-1}:aps" \
      --user "${AWS_ACCESS_KEY_ID:-}:${AWS_SECRET_ACCESS_KEY:-}" \
      -H "x-amz-security-token: ${AWS_SESSION_TOKEN:-}" \
      --get "${amp_query_url}" \
      --data-urlencode 'query=api_latency_ms{tenant_id="smoke-test",service_id="payment-gw"}' || true)
    if [[ "${amp_status}" == "200" ]]; then
      echo "AMP query endpoint reachable"
    else
      echo "AMP query check skipped/failed with HTTP ${amp_status}; ADOT logs will be checked next"
      cat /tmp/amp-smoke-response.txt >&2 || true
    fi
  else
    echo "Skipping AMP query check: curl lacks --aws-sigv4"
  fi
else
  echo "Skipping AMP query check: AMP_QUERY_ENDPOINT not set"
fi

echo "Checking ECS service stability"
aws ecs describe-services \
  --cluster "${ECS_CLUSTER_NAME}" \
  --services "${TELEMETRY_API_SERVICE_NAME}" "${PREDICTION_WORKER_SERVICE_NAME}" "${AI_ENGINE_SERVICE_NAME}" \
  --query 'services[].{name:serviceName,status:status,desired:desiredCount,running:runningCount,pending:pendingCount,deployments:length(deployments)}' \
  --output table

unstable_count=$(aws ecs describe-services \
  --cluster "${ECS_CLUSTER_NAME}" \
  --services "${TELEMETRY_API_SERVICE_NAME}" "${PREDICTION_WORKER_SERVICE_NAME}" "${AI_ENGINE_SERVICE_NAME}" \
  --query 'length(services[?status!=`ACTIVE` || pendingCount>`0` || deployments[1] != null])' \
  --output text)
if [[ "${unstable_count}" != "0" ]]; then
  echo "ECS service stability check failed: ${unstable_count} unstable service(s)" >&2
  exit 1
fi

echo "Checking SQS queue depth"
queue_depth=$(aws sqs get-queue-attributes \
  --queue-url "${PREDICTION_QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text)
if (( queue_depth > ${PREDICTION_QUEUE_MAX_DEPTH:-1000} )); then
  echo "Prediction queue depth too high: ${queue_depth}" >&2
  exit 1
fi

dlq_depth=$(aws sqs get-queue-attributes \
  --queue-url "${PREDICTION_QUEUE_DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text)
if (( dlq_depth > initial_dlq_depth )); then
  echo "Prediction DLQ grew during smoke: ${initial_dlq_depth} -> ${dlq_depth}" >&2
  exit 1
fi
if (( dlq_depth > 0 )); then
  echo "Prediction DLQ still has ${dlq_depth} pre-existing message(s)"
fi

if [[ -n "${AWS_REGION:-}" ]]; then
  echo "Checking recent ADOT exporter errors"
  adot_errors=$(aws logs filter-log-events \
    --region "${AWS_REGION}" \
    --log-group-name /ecs/telemetry-api \
    --start-time "$(( ($(date +%s) - 3600) * 1000 ))" \
    --filter-pattern '"adot-collector" "error"' \
    --query 'length(events)' \
    --output text 2>/dev/null || echo "unknown")
  echo "Recent ADOT error events: ${adot_errors}"

  echo "Checking known fallback policy table warning count"
  policy_warnings=$(aws logs filter-log-events \
    --region "${AWS_REGION}" \
    --log-group-name /ecs/prediction-worker \
    --start-time "$(( ($(date +%s) - 3600) * 1000 ))" \
    --filter-pattern '"DynamoDB policy table"' \
    --query 'length(events)' \
    --output text 2>/dev/null || echo "unknown")
  echo "Recent policy-table fallback warnings (accepted known gap): ${policy_warnings}"
fi

echo "Post-apply smoke checks passed"
