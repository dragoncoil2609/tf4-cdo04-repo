# CDO-04 SLO Early-Warning Control Plane -- Infrastructure

Terraform IaC for the SLO Early-Warning Control Plane (CDO-04). Deploys to a
single `us-east-1` AWS account, environment-separated by state key and resource
naming.

## Layout

```
infra/
├── bootstrap/               # One-time: S3 state backend, GitHub OIDC, deploy role
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   └── README.md
├── terraform/               # Main Terraform root
│   ├── backend.tf           # S3 remote state (replace placeholders after bootstrap)
│   ├── versions.tf          # >= 1.10.0, aws >= 5.80.0
│   ├── main.tf              # Root -- wires networking, data, compute, observability
│   ├── variables.tf         # Required + optional variables
│   ├── outputs.tf           # VPC, ALB, ECS, AMP, SQS, S3, observability outputs
│   ├── terraform.tfvars.example
│   ├── modules/
│   │   ├── networking/      # VPC, subnets, NAT, SGs, S3+DynamoDB Gateway Endpoints
│   │   ├── data/            # AMP, DynamoDB, SQS/DLQs, S3 evidence, Secrets, KMS, SNS
│   │   ├── compute/         # ALB, ECR, ECS Fargate, Service Connect, EventBridge Scheduler
│   │   └── observability/   # CloudWatch Logs, Alarms, Dashboard, Budget
│   └── README.md
└── README.md                # This file
```

## Bootstrap (one-time per account)

```bash
cd infra/bootstrap
terraform init
terraform plan
terraform apply
```

Bootstrap creates:
- **S3 state bucket** -- versioned, AES256-encrypted, public-access blocked,
  TLS-only bucket policy, lifecycle-moves noncurrent versions to STANDARD_IA
  (30 days) and expires them (180 days). `lifecycle.prevent_destroy = true`.
- **GitHub OIDC provider** -- trusts `token.actions.githubusercontent.com`,
  audience `sts.amazonaws.com`.
- **Terraform backend role** (`/github-actions/`) -- least-privilege trust policy
  restricted to `repo:<org>/<repo>:ref:refs/heads/<branch>`. Inline policy
  grants only S3 state bucket CRUD + `sts:GetCallerIdentity`; broader main
  deploy role is environment-specific and separate.

Override defaults:
```bash
terraform apply -var="github_org=my-org" -var="github_repo=my-repo" -var="github_branch=main"
```

Applied sandbox backend bucket: `tf4-cdo04-terraform-state-7na270jm` in `us-east-1`.
For new environments, copy `backend_config_snippet` output into
`infra/terraform/backend.tf`, replacing `<environment>` with `staging` or `prod`.

## Backend (S3 only -- no DynamoDB lock table)

State locking uses Terraform >= 1.10 native **S3 lockfile** (`use_lockfile = true`).
DynamoDB lock table is **not used** (deprecated per AWS/Terraform guidance).

The backend block in `infra/terraform/backend.tf` now uses sandbox state:

```hcl
bucket       = "tf4-cdo04-terraform-state-7na270jm"
key          = "tf4-cdo04/sandbox/terraform.tfstate"
region       = "us-east-1"
use_lockfile = true
```

For staging/prod, change only the backend key after bootstrap bucket exists.

### Environment state key pattern

```
tf4-cdo04/sandbox/terraform.tfstate
tf4-cdo04/staging/terraform.tfstate
tf4-cdo04/prod/terraform.tfstate
```

Terraform backend blocks cannot use variable interpolation, so each environment
needs its own `backend.tf` or a `-backend-config` partial:

```bash
terraform init -backend-config="key=tf4-cdo04/staging/terraform.tfstate"
```

## Main Terraform root

Four modules wired by `infra/terraform/main.tf`:

| Module | Purpose |
|---|---|
| `networking` | VPC, public/private subnets (2 AZs), 1 NAT Gateway, IGW, S3 + DynamoDB Gateway Endpoints, ALB + ECS + Worker + AI Engine security groups |
| `data` | AMP workspace, DynamoDB audit + policy tables, SQS prediction queue + DLQ, S3 evidence bucket (KMS key), Secrets Manager, SNS alert topic |
| `compute` | ECR repos, ECS cluster, 4 Fargate services (Telemetry API, Prediction Worker, AI Engine, ADOT Collector), public ALB, ECS Service Connect, EventBridge Scheduler |
| `observability` | CloudWatch dashboard, alarms (ALB 5xx/latency/unhealthy hosts, ECS CPU/Memory, SQS queue depth/DLQ depth/age, DynamoDB throttles/system errors), SNS topic, AWS Budget |

### Key design decisions

- **ECS Fargate** on Linux/x86, `awsvpc` network mode, `assignPublicIp = DISABLED`.
- **ECS Service Connect** for Worker -> AI Engine communication (no internal ALB).
- **ADOT/Prometheus Collector** runs as a standalone ECS service with Service Connect
  alias `adot-collector`. App services send OTLP telemetry (gRPC 4317 / HTTP 4318)
  via `OTEL_EXPORTER_OTLP_ENDPOINT=http://adot-collector:4318`. The collector
  batch-processes and SigV4 `remote_write`s to AMP. Defaults to public ADOT image
  (`public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0`) when
  `adot_collector_image_tag` is empty. A dedicated security group allows OTLP
  ingress from the API, Worker, and AI Engine services.
- **AMP** reachable via NAT for MVP. PrivateLink endpoints (`aps-workspaces` for
  data-plane, regional STS) are post-MVP.
- **EventBridge Scheduler** for periodic prediction jobs, with SQS DLQ for
  failed scheduler targets. Scheduler resources are created only when
  `enable_services = true`.
- **ECS rolling deployment** with circuit breaker for Telemetry API, Prediction Worker, and AI Engine. ADOT Collector uses ECS rolling deploy without circuit breaker. Blue/green
  and CodeDeploy are post-MVP.
- **HTTPS** enforced for non-sandbox via `acm_certificate_arn`; HTTP redirects
  to HTTPS outside sandbox. Sandbox may use HTTP-only. Terraform rejects
  `0.0.0.0/0` and `::/0` ingress outside sandbox. Terraform does **not** create
  Route53 or ACM resources -- you must provision the certificate separately at
  `us-east-1`.

### Required variables

| Variable | Required | Notes |
|---|---|---|
| `allowed_ingress_cidrs` | **yes** | CIDRs allowed to reach the public ALB. No default -- must be explicit. |
| `acm_certificate_arn` | for non-sandbox | ACM certificate ARN in `us-east-1`. Sandbox may leave empty for HTTP. |
| `alert_email` | no | SNS alert subscription email (confirmed manually). |
| `enable_services` | no | Default `false`. Set `true` after images are pushed to ECR. |

Full variable list and defaults are in `variables.tf` and
`terraform.tfvars.example`.

## Commands

```bash
cd infra/terraform

# 1. Initialize (after filling backend.tf)
terraform init

# 2. Copy and customize variables
cp terraform.tfvars.example terraform.tfvars

# 3. Plan infrastructure only (no ECS services yet)
terraform plan -var="enable_services=false"

# 4. Apply infrastructure (requires user approval)
terraform apply -var="enable_services=false"

# 5. After CI pushes images, apply with services
terraform apply -var="enable_services=true"

# 6. Destroy
terraform destroy
```

`terraform apply` without `-auto-approve` requires explicit user confirmation
before mutating AWS resources.

## Cost guardrails

- **Single NAT Gateway** in the first public AZ (not one per AZ).
- **S3 and DynamoDB Gateway VPC Endpoints** (free tier) route private subnet
  traffic to S3 and DynamoDB without traversing the NAT.
- **AWS Budget** (`budget_limit`, default $200/month) with 50%, 80%, and
  100% alerts to `alert_email`.

## SNS email confirmation

SNS email subscriptions require **manual confirmation** via the confirmation
link sent to `alert_email`. Terraform does not and cannot auto-confirm.

## Out of scope

- WAF (Web Application Firewall)
- CodeDeploy blue/green deployments
- ECS Service Connect TLS / Private CA
- Full VPC Interface Endpoints beyond S3/DynamoDB Gateway Endpoints
- Multi-account or multi-region DR
- Route53 DNS / ACM certificate provisioning
- Auto-confirmation of SNS email subscriptions
- DynamoDB state lock table (deprecated; S3 lockfile used instead)

## Ownership

- **Sonnet** -- implements Terraform code only (no apply).
- **Opus** -- owns QA review, mock E2E validation, `terraform apply`, and
  post-apply observation.

## Mock E2E Application

A minimal single-container mock app lives in `src/mock-e2e/`. One Dockerfile,
one `app.py` switched by the `MOCK_ROLE` env var. It covers the full data path:
ingest -> SQS -> worker -> AI engine -> DynamoDB + S3.

### Mock roles

| `MOCK_ROLE` | Port | Behavior |
|-------------|------|----------|
| `api`     | 8080 | GET /health, POST /v1/ingest -> SQS |
| `ai`      | 8080 | GET /health, POST /v1/predict -> fake risk JSON |
| `worker`  | none | Poll SQS -> call AI -> write DynamoDB + S3 smoke/ -> delete msg |

Worker runs no HTTP server; ECS health check is `CMD true`.

### Build and push (one image, three ECR repos)

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
TAG=smoke-$(date -u +%Y%m%d%H%M%S)
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
docker build -t mock-e2e:$TAG src/mock-e2e

for repo in \
  tf4-cdo04-sandbox-telemetry-api \
  tf4-cdo04-sandbox-prediction-worker \
  tf4-cdo04-sandbox-ai-engine; do
  docker tag mock-e2e:$TAG "$REGISTRY/$repo:$TAG"
  docker push "$REGISTRY/$repo:$TAG"
done
```

### Terraform apply (after bootstrap)

```bash
cd infra/terraform
MYIP=$(curl -s https://checkip.amazonaws.com | tr -d '\r\n')
terraform apply \
  -var="enable_services=true" \
  -var="allowed_ingress_cidrs=[\"${MYIP}/32\"]" \
  -var="telemetry_api_image_tag=${REGISTRY}/tf4-cdo04-sandbox-telemetry-api:${TAG}" \
  -var="prediction_worker_image_tag=${REGISTRY}/tf4-cdo04-sandbox-prediction-worker:${TAG}" \
  -var="ai_engine_image_tag=${REGISTRY}/tf4-cdo04-sandbox-ai-engine:${TAG}"
```

The task definitions set `MOCK_ROLE` per service: `api`, `worker`, `ai`.
Terraform also outputs ECR repository URLs:

```bash
terraform output telemetry_api_ecr_repository_url
terraform output prediction_worker_ecr_repository_url
terraform output ai_engine_ecr_repository_url
```

Evidence bucket policy denies non-TLS and unencrypted uploads. Mock worker writes
S3 evidence with `ServerSideEncryption=aws:kms`.

### Post-apply E2E smoke

1. Confirm ECS services reach steady state.
2. Confirm ALB target group shows healthy API targets.
3. POST telemetry JSON to `http://<alb_dns_name>/v1/ingest` and expect `202`.
4. Verify prediction queue drains and DLQs stay empty.
5. Verify Worker logs show AI call, DynamoDB write, S3 write, and message delete.
6. Verify audit writes appear in DynamoDB audit table for `tenant_id=mock-e2e`.
7. Check S3 evidence bucket `smoke/` prefix for JSON artifacts.
8. Check CloudWatch dashboard and alarms after metrics settle.
9. Send a test alert through SNS (confirm manual subscription first).
