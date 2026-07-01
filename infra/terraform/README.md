# Terraform Root -- CDO-04 Platform

Main Terraform root that wires together the four infrastructure modules:
networking, data, compute, and observability.

## Prerequisites

1. Bootstrap applied first (`infra/bootstrap/`).
2. S3 backend configured in `backend.tf` with real bucket/key/region values
   from bootstrap output `backend_config_snippet`.
3. Docker images built and pushed to ECR (or `enable_services = false` for
   infra-only apply).
4. Terraform >= 1.10.0, AWS provider >= 5.80.0.

## Backend configuration

State locking uses Terraform >= 1.10 native **S3 lockfile**
(`use_lockfile = true`). DynamoDB lock table is **not used** (deprecated per
AWS/Terraform guidance).

The `backend.tf` file is configured for sandbox remote state:

```hcl
bucket       = "tf4-cdo04-terraform-state-7na270jm"
key          = "tf4-cdo04/sandbox/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
```

Terraform does NOT allow variable interpolation in backend blocks, so staging/prod
need a manual key change or separate backend config.

Environment state keys:

```
tf4-cdo04/sandbox/terraform.tfstate
tf4-cdo04/staging/terraform.tfstate
tf4-cdo04/prod/terraform.tfstate
```

Alternatively, use partial backend configuration:

```bash
terraform init -backend-config="key=tf4-cdo04/staging/terraform.tfstate"
```

## Quick start

```bash
cd infra/terraform

# 1. backend.tf already points to sandbox state bucket from bootstrap.

# 2. Copy and customize terraform.tfvars:
cp terraform.tfvars.example terraform.tfvars

# 3. Initialize (requires backend.tf to be filled in)
terraform init

# 4. Plan and apply infrastructure only (no ECS services yet)
terraform plan   -var="enable_services=false"
terraform apply  -var="enable_services=false"

# 5. After CI pushes images, apply with services enabled
terraform apply -var="enable_services=true" -var="telemetry_api_image_tag=..."

# 6. Destroy
terraform destroy
```

`terraform apply` is run without `-auto-approve` -- explicit user confirmation
is required before mutating AWS resources.

## Module overview

Each module (`modules/networking`, `modules/data`, `modules/compute`,
`modules/observability`) is a self-contained Terraform module with its own
`main.tf`, `variables.tf`, and `outputs.tf`. The root `main.tf` documents
the expected inputs and outputs at each module call site.

| Module | Purpose |
|---|---|
| `networking` | VPC, public/private subnets (2 AZs), 1 NAT Gateway, IGW, S3 + DynamoDB Gateway Endpoints, ALB + ECS + Worker + AI Engine security groups |
| `data` | AMP workspace, DynamoDB audit + policy tables, SQS prediction queue + DLQ, S3 evidence bucket (KMS key), Secrets Manager, SNS alert topic |
| `compute` | ECR repos, ECS cluster, 3 Fargate services (API, Worker, AI Engine), ADOT Collector sidecar in telemetry API task, API Gateway HTTP API/VPC Link, internal ALB, ECS Service Connect fallback, EventBridge Scheduler |
| `observability` | CloudWatch alarms (ALB 5xx/latency/unhealthy, ECS CPU/Memory, SQS depth/age/DLQ, DynamoDB throttles/errors), CloudWatch dashboard, SNS topic, AWS Budget |

## Variables

| Variable | Required | Default | Notes |
|---|---|---|---|
| `project_name` | No | `tf4-cdo04` | Used in resource naming and tags |
| `environment` | No | `sandbox` | `sandbox` / `staging` / `prod` |
| `aws_region` | No | `us-east-1` | Deploy region |
| `vpc_cidr` | No | `10.0.0.0/16` | VPC CIDR |
| `az_count` | No | `2` | Min 2 for ALB |
| `enable_acm` | No | `true` | Keep ACM certificate managed for future API Gateway custom domain |
| `telemetry_api_image_tag` | No | `MOCK_PLACEHOLDER...` | ECR URI after CI build |
| `prediction_worker_image_tag` | No | `MOCK_PLACEHOLDER...` | ECR URI after CI build |
| `ai_engine_image_tag` | No | `MOCK_PLACEHOLDER...` | ECR URI after CI build |
| `adot_collector_image_tag` | No | `""` | Empty = fall back to public ADOT image (`public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0`) |
| `enable_services` | No | `false` | Toggle ECS services; set `true` after images pushed to ECR |
| `alert_email` | No | `""` | SNS alert email (subscription must be confirmed manually) |
| `budget_limit` | No | `200` | Monthly budget in USD |

## Key design decisions

- **ADOT/collector**: When `adot_collector_image_tag` is empty, the
  compute module falls back to the public ADOT collector image
  (`public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0`).
  The collector runs as a **sidecar container in the telemetry-api ECS task**
  (same `awsvpc` network namespace). It scrapes `localhost:8080/metrics`
  from the telemetry-api container and remote_writes Prometheus samples to AMP
  using IAM SigV4 (`sigv4auth`).
  Configuration is embedded inline via `AOT_CONFIG_CONTENT` environment variable;
  no custom image build or SSM parameter is required.
  A **standalone ADOT ECS service** with Service Connect alias `adot-collector`
  and OTLP ingress (gRPC 4317 / HTTP 4318) is deferred post-MVP.
- **Path A Worker -> AI**: Worker private subnet egresses through existing NAT Gateway to API Gateway `execute-api`; API Gateway HTTP API enforces `AWS_IAM`/SigV4, then uses VPC Link to the internal ALB listener `:80` and AI target group.
- **ECS Service Connect** remains enabled for Worker -> AI rollback/fallback during migration.
- **Single NAT Gateway** in the first public AZ to minimize cost.
- **S3 and DynamoDB Gateway VPC Endpoints** (free tier) to avoid NAT data
  transfer charges for S3/DynamoDB traffic.
- **ECS Fargate private tasks** (`assignPublicIp = DISABLED`), `awsvpc` mode.
- **ECS rolling deployment** with circuit breaker for API, Worker, and AI Engine.
  Blue/green via CodeDeploy is post-MVP.
- **HTTPS via existing ACM certificate** for non-sandbox; cert must already
  exist in `us-east-1`. Terraform manages ACM certificate only; Route53/Name.com DNS remains manual.
- **Budget**: Default $200/month via `budget_limit`, alerts to `alert_email`.

## SNS email confirmation

SNS email subscriptions require **manual confirmation**. After apply, check
the inbox for `alert_email` and click the confirmation link. Terraform cannot
auto-confirm.

## Outputs

Full output list is in `outputs.tf`. Key outputs for consumers:

| Output | Description |
|---|---|
| `alb_dns_name` | Public ALB DNS for `/v1/ingest` |
| `ai_api_gateway_endpoint` | SigV4-protected API Gateway endpoint for Worker -> AI |
| `amp_remote_write_endpoint` | AMP remote write endpoint (ADOT collector target) |
| `amp_query_endpoint` | AMP query endpoint (Prediction Worker PromQL) |
| `prediction_queue_url` | SQS prediction queue URL |
| `audit_table_name` | DynamoDB audit table name |
| `evidence_bucket_name` | S3 evidence bucket name |
| `dashboard_url` | CloudWatch dashboard URL |
| `sns_alert_topic_arn` | SNS alert topic ARN |
