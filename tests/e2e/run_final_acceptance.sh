#!/usr/bin/env bash
# Final acceptance orchestrator.
# Runs smoke, scenario, k6, security, cost, and eval gates into evidence/logs/.
set -euo pipefail

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 2
  fi
}

require API_GATEWAY_BASE_URL
require ECS_CLUSTER_NAME
require TELEMETRY_API_SERVICE_NAME
require PREDICTION_WORKER_SERVICE_NAME
require AI_ENGINE_SERVICE_NAME
require PREDICTION_QUEUE_URL
require PREDICTION_QUEUE_DLQ_URL
require DYNAMODB_AUDIT_TABLE

resolve_api_gateway_base_url() {
  local endpoint="${API_GATEWAY_BASE_URL}"
  case "${endpoint}" in
    http://*|https://*) printf '%s\n' "${endpoint%/}" ;;
    *) printf '%s\n' "https://${endpoint%/}" ;;
  esac
}

AWS_REGION="${AWS_REGION:-us-east-1}"
API_GATEWAY_BASE_URL="$(resolve_api_gateway_base_url)"
mkdir -p evidence/logs

log_step() {
  printf '\n== %s ==\n' "$1"
}

queue_attrs() {
  local url="$1" out="$2"
  aws sqs get-queue-attributes \
    --region "${AWS_REGION}" \
    --queue-url "${url}" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed \
    > "${out}"
}

ecs_snapshot() {
  local out="$1"
  aws ecs describe-services \
    --region "${AWS_REGION}" \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${TELEMETRY_API_SERVICE_NAME}" "${PREDICTION_WORKER_SERVICE_NAME}" "${AI_ENGINE_SERVICE_NAME}" \
    > "${out}"
}

log_step "pre snapshots"
queue_attrs "${PREDICTION_QUEUE_URL}" evidence/logs/pre-queue.json
queue_attrs "${PREDICTION_QUEUE_DLQ_URL}" evidence/logs/pre-dlq.json
ecs_snapshot evidence/logs/pre-ecs-services.json

log_step "post-apply smoke"
bash scripts/post_apply_smoke.sh | tee evidence/logs/final-smoke.log

if [[ "${RUN_SINGLE_PIPELINE:-0}" == "1" ]]; then
  log_step "single-service AI pipeline acceptance"
  bash tests/e2e/acceptance_ai_pipeline.sh
else
  echo "RUN_SINGLE_PIPELINE not set -> single-service pipeline skipped; TF4 scenario matrix is primary complete-window proof"
fi

if [[ "${SKIP_SCENARIO_MATRIX:-0}" != "1" ]]; then
  log_step "TF4 scenario matrix"
  bash tests/e2e/tf4_scenario_matrix.sh
else
  echo "SKIP_SCENARIO_MATRIX=1 -> skipped" | tee evidence/logs/tf4-scenario-summary.json
fi

if [[ "${SKIP_K6:-0}" != "1" ]]; then
  log_step "k6 50 RPS acceptance"
  k6 run tests/k6/acceptance_ingest.js \
    -e TELEMETRY_API_HOST="${API_GATEWAY_BASE_URL}" \
    -e RATE=50 \
    -e DURATION="${ACCEPTANCE_K6_DURATION:-10m}" \
    --summary-export evidence/logs/acceptance-50rps-summary.json

  log_step "k6 100 RPS acceptance"
  k6 run tests/k6/acceptance_ingest.js \
    -e TELEMETRY_API_HOST="${API_GATEWAY_BASE_URL}" \
    -e RATE=100 \
    -e DURATION="${ACCEPTANCE_K6_DURATION:-10m}" \
    --summary-export evidence/logs/acceptance-100rps-summary.json
else
  echo "SKIP_K6=1 -> skipped"
fi

if [[ "${SKIP_SECURITY:-0}" != "1" ]]; then
  log_step "security probes"
  bash tests/e2e/security_probes.sh
else
  echo "SKIP_SECURITY=1 -> skipped"
fi

log_step "post snapshots"
queue_attrs "${PREDICTION_QUEUE_URL}" evidence/logs/post-final-queue.json
queue_attrs "${PREDICTION_QUEUE_DLQ_URL}" evidence/logs/post-final-dlq.json
ecs_snapshot evidence/logs/post-final-ecs-services.json

if [[ "${SKIP_COST:-0}" != "1" ]]; then
  log_step "cost evidence"
  START_DATE="${COST_START_DATE:-$(date -u -d '7 days ago' +%F)}"
  END_DATE="${COST_END_DATE:-$(date -u -d 'tomorrow' +%F)}"
  aws ce get-cost-and-usage \
    --time-period "Start=${START_DATE},End=${END_DATE}" \
    --granularity DAILY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --region "${AWS_REGION}" \
    > evidence/logs/cost-explorer-final.json || true
  if [[ -n "${AWS_ACCOUNT_ID:-}" && -n "${BUDGET_NAME:-}" ]]; then
    aws budgets describe-budget \
      --account-id "${AWS_ACCOUNT_ID}" \
      --budget-name "${BUDGET_NAME}" \
      --region "${AWS_REGION}" \
      > evidence/logs/budget-final.json || true
  else
    printf '{"skipped":"AWS_ACCOUNT_ID or BUDGET_NAME not set"}\n' > evidence/logs/budget-final.json
  fi
else
  echo "SKIP_COST=1 -> skipped"
fi

log_step "eval report"
python tests/e2e/eval_report.py

log_step "final evidence paths"
cat <<'EOF'
evidence/logs/final-smoke.log
evidence/logs/acceptance-ai-audit-scan.json (only when RUN_SINGLE_PIPELINE=1)
evidence/logs/tf4-scenario-summary.json
evidence/logs/eval-report.json
evidence/logs/eval-report.md
evidence/logs/acceptance-50rps-summary.json
evidence/logs/acceptance-100rps-summary.json
evidence/logs/security-probes.json
evidence/logs/post-final-ecs-services.json
evidence/logs/post-final-queue.json
evidence/logs/post-final-dlq.json
evidence/logs/budget-final.json
evidence/logs/cost-explorer-final.json
EOF
