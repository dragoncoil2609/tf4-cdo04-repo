# Scripts

Helper scripts for local checks and CI post-deploy smoke tests.

## `post_apply_smoke.sh`

Runs after Terraform apply in CI. It checks:

- ALB `/health`
- `POST /v1/ingest`
- ECS service stability
- prediction SQS queue depth
- prediction DLQ depth

Required env vars:

```bash
ALB_DNS_NAME=...
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
