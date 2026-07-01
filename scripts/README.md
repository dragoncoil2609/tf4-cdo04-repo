# Scripts

Helper scripts for local checks and CI post-deploy smoke tests.

## `post_apply_smoke.sh`

Runs after Terraform apply in CI. It checks:

- API Gateway `/health`
- `POST /v1/ingest`
- unsigned `POST /v1/predict` is denied by IAM auth
- signed `POST /v1/predict` reaches AI Engine when curl SigV4 is available
- ECS service stability
- prediction SQS queue depth
- prediction DLQ depth

Required env vars:

```bash
API_GATEWAY_BASE_URL=...
ECS_CLUSTER_NAME=...
TELEMETRY_API_SERVICE_NAME=...
PREDICTION_WORKER_SERVICE_NAME=...
AI_ENGINE_SERVICE_NAME=...
PREDICTION_QUEUE_URL=...
PREDICTION_QUEUE_DLQ_URL=...
```

Local syntax check:

```bash
bash -n scripts/post_apply_smoke.sh
```

This is harness prep only. Real pass/fail evidence belongs in final E2E.
