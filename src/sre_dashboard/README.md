# CDO SRE Dashboard — Local Operational Visibility

A local-only FastAPI backend for operational visibility into CDO capacity
management infrastructure. Runs on `127.0.0.1:8001` in Docker or directly
with Python.

## Quick Start

### Prerequisites

- Python 3.10+
- AWS SSO login (`aws sso login --profile <name>`)
- Terraform state directory (or cached `terraform-output.json`)

### Run with Python

```bash
cd tf4-cdo04-repo/src/sre_dashboard
pip install -r requirements.txt
python -m sre_dashboard.main
```

### Run with Docker Compose

```bash
cd tf4-cdo04-repo/src/sre_dashboard
docker compose up --build
```

The service is bound to `127.0.0.1:8001` — **no external network access**.

## Configuration

All settings via environment variables:

| Variable | Default | Description |
|---|---|---|
| `APP_NAME` | `sre-dashboard` | Service name |
| `APP_VERSION` | `0.1.0` | Version |
| `LOG_LEVEL` | `INFO` | Logging level |
| `HOST` | `127.0.0.1` | Bind address |
| `PORT` | `8001` | Listen port |
| `AWS_REGION` | `us-east-1` | AWS region |
| `AWS_PROFILE` | _(none)_ | AWS SSO profile name |
| `TERRAFORM_OUTPUT_DIR` | `/terraform` | Terraform state directory |
| `DYNAMODB_AUDIT_TABLE` | `cdo04-audit-logs` | Audit DynamoDB table |
| `DYNAMODB_POLICY_TABLE` | `cdo04-service-policies` | Policy DynamoDB table |

## Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| GET | `/api/profiles` | List available AWS profiles |
| POST | `/api/session` | Login with AWS profile |
| GET | `/api/session` | Current session info |
| DELETE | `/api/session` | Logout |
| POST | `/api/session/refresh` | Refresh session |
| GET | `/api/probes` | AWS permission probes |
| GET | `/api/tenants` | List tenants |
| GET | `/api/services?tenant_id=...` | List services for tenant |
| GET | `/api/overview?tenant_id=...` | Aggregated overview |
| GET | `/api/metrics/{service_id}?tenant_id=...` | All 7 metrics |
| GET | `/api/metrics/{service_id}/{metric_type}?tenant_id=...` | Single metric |
| GET | `/api/audits?tenant_id=...` | Audit logs |
| GET | `/api/policies?tenant_id=...` | List policies |
| PUT | `/api/policies/{tenant_id}/{service_name}` | Update policy |
| GET | `/api/alarms` | CloudWatch alarms |
| GET | `/api/queue` | SQS queues |
| GET | `/api/ecs` | ECS services |

## Security

- Binds to `127.0.0.1` only — no external access
- Never returns AWS credentials via API
- No raw PromQL input endpoint
- SQS client only calls `GetQueueAttributes` — never `ReceiveMessage`
- DynamoDB policy updates use conditional writes
- All probes are read-only
