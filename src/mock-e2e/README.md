# Mock E2E app

Minimal reference app for CDO-04 infrastructure smoke tests. Same image runs all
three roles through `MOCK_ROLE` so Terraform can prove the full platform path
without real product code.

## Roles

| `MOCK_ROLE` | Behavior |
|---|---|
| `api` | `GET /health`; `POST /v1/ingest` writes message to SQS. |
| `worker` | Polls SQS, calls AI, writes DynamoDB audit item and S3 evidence object, deletes message. |
| `ai` | `GET /health`; `POST /v1/predict` returns deterministic fake risk JSON. |

## Contract

Required environment:

- API: `PREDICTION_QUEUE_URL`
- Worker: `PREDICTION_QUEUE_URL`, `AI_ENGINE_URL`, `AUDIT_TABLE_NAME`, `EVIDENCE_BUCKET_NAME`
  (S3 writes set `ServerSideEncryption=aws:kms` to match bucket policy)
- AI: none beyond optional `PORT`

Data path:

```text
ALB /v1/ingest -> API -> SQS -> Worker -> AI -> DynamoDB + S3 smoke/
```

## Build

```bash
docker build -t mock-e2e:local src/mock-e2e
```

## Local syntax check

```bash
python -m py_compile src/mock-e2e/app.py
```
