# Curveball Responses

## Curveball #1 - ADOT rollback on telemetry-api

- **Prompt**: ECS service deployment rolled back for `tf4-cdo04-sandbox-telemetry-api:11`; check logs.
- **Impact**: Telemetry API task stopped because essential `adot-collector` exited `1`; app container later exited `137` when task was stopped.
- **Decision**: Remove unsupported `sending_queue` from ADOT config for collector image `public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0`; keep `retry_on_failure` only where supported.
- **Implementation changes**: Updated Terraform inline ADOT config in `infra/terraform/modules/compute/telemetry_api.tf` and reference config `src/telemetry_api/adot-config.yaml`.
- **Evidence link**: final healthy deployment in `evidence/post-final-ecs-services.json`; bounded final logs in `evidence/post-final-telemetry-tail-30m.log`.

## Curveball #2 - Gitleaks `curl-auth-user` false positive

- **Prompt**: Gitleaks failed on `scripts/post_apply_smoke.sh` line using `curl --aws-sigv4 --user`.
- **Impact**: CI security scan blocked deploy even though credentials were environment-variable references, not hardcoded secrets.
- **Decision**: Add narrow allowlist for exact SigV4 env-var curl pattern and wire Gitleaks action to config file.
- **Implementation changes**: Created `.gitleaks.toml`; added `config-path: .gitleaks.toml` to `.github/workflows/deploy.yml`.
- **Evidence link**: `.gitleaks.toml`; smoke script still uses `--user "${AWS_ACCESS_KEY_ID:-}:${AWS_SECRET_ACCESS_KEY:-}"` with runtime env vars only.

## Curveball #3 - Invalid SQS queue age baseline

- **Prompt**: `ApproximateAgeOfOldestMessage` was used as SQS queue attribute.
- **Impact**: Baseline collection failed because queue age is CloudWatch metric, not valid `get-queue-attributes` attribute.
- **Decision**: Collect SQS depth via valid SQS attributes and collect age via CloudWatch `AWS/SQS ApproximateAgeOfOldestMessage` metric.
- **Implementation changes**: Final evidence includes `pre-queue-age.json` and `post-final-queue-age.json` from CloudWatch metric statistics.
- **Evidence link**: `evidence/pre-queue.json`, `evidence/pre-queue-age.json`, `evidence/post-final-queue.json`, `evidence/post-final-queue-age.json`.

## Curveball #4 - k6 final scenarios completed but failed thresholds

- **Prompt**: Continue remaining E2E work after all k6 scenarios finished.
- **Impact**: All four k6 scenarios completed and wrote evidence, but every scenario exited `99` because thresholds were crossed.
- **Decision**: Do not rerun or hide failures. Capture final AWS evidence, mark QA gate failed, and document exact bottlenecks.
- **Implementation changes**: Updated `docs/07_test_eval_report.md`, `tests/README.md`, and `evidence/README.md` with measured values.
- **Evidence link**: `evidence/k6-sc01-summary.json`, `evidence/k6-sc02-summary.json`, `evidence/k6-sc03-summary.json`, `evidence/k6-sc04-summary.json`.

## Curveball #5 - Full AI E2E not proven by final audit scan

- **Prompt**: Verify AI works and then finish full E2E evidence.
- **Impact**: Direct AI private smoke passed (`AI_SMOKE_STATUS 200`), but DynamoDB final scan showed partial-window/static fallback records only. Scheduler → AMP query_range → Worker → AI Engine → DynamoDB audit was not proven for k6 scenarios.
- **Decision**: Report as gate failure, not success. Keep fallback-policy implementation as separate handoff; do not expand scope here.
- **Implementation changes**: QA docs now separate direct AI endpoint health from full prediction pipeline proof.
- **Evidence link**: `evidence/ai-smoke-client.log`, `evidence/ai-smoke-server-events.json`, `evidence/post-final-audit-scan.json`.
