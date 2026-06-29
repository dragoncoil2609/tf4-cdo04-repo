# CDO-04 Infrastructure -- Terraform ownership slice

This folder now tracks only Nguyễn Thành Vinh's assignee-owned Terraform work.
Reviewer-only responsibilities and teammate-owned implementation are intentionally
left as `TODO (CPOA-xx)` placeholders in Terraform files.

## Kept Vinh-owned scope

| Jira | Scope | Location |
|---|---|---|
| CPOA-37 | Terraform S3 backend | `bootstrap/` |
| CPOA-39 | Networking module | `terraform/modules/networking/` |
| CPOA-41 | ECS Cluster + Service Connect namespace | `terraform/modules/compute/` |
| CPOA-42 | Data module foundation: AMP, SQS/DLQ, DynamoDB audit, S3 evidence | `terraform/modules/data/` |
| CPOA-46 | Telemetry API task definition | `terraform/modules/compute/` |
| CPOA-50 | ECS autoscaling policy | placeholder only, not implemented yet |

## Removed / placeholder teammate-owned scope

| Jira | Owner | Placeholder |
|---|---|---|
| CPOA-38 | Truong An | GitHub OIDC deploy role |
| CPOA-40 | Truong An | Security Groups module/rules |
| CPOA-43 | Truong An | KMS + Secrets/SSM config |
| CPOA-44 | Truong An | EventBridge Scheduler |
| CPOA-47..CPOA-49/CPOA-51 | Truong An | Worker/AI task defs, AI Service Connect, AI S3 access |
| CPOA-78 | Nguyen Huy Hoang | CI/CD, deployment, ECR push, smoke deploy |
| CPOA-88 | Nguyen Quach Khang Ninh | Observability dashboards/alarms/tests |
| CPOA-98 | Huy Tạ Hoàng | Cost & operations budget/reporting |

## Layout

```text
infra/
├── bootstrap/             # CPOA-37 backend bucket only
└── terraform/
    ├── main.tf            # wires Vinh-owned modules only
    ├── backend.tf         # S3 backend config
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars.example
    └── modules/
        ├── networking/    # CPOA-39
        ├── data/          # CPOA-42
        ├── compute/       # CPOA-41/CPOA-46/CPOA-50 placeholder
        └── observability/ # placeholder for CPOA-88 owner
```

## Bootstrap

```bash
cd infra/bootstrap
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

Apply only when backend bucket needs creation:

```bash
terraform apply
```

## Main Terraform

```bash
cd infra/terraform
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

Current main root should create only foundational resources from Vinh scope.
It does not expose public ALB ingress, deploy ECS services, schedule jobs, or
create dashboards/budgets until teammate-owned placeholders are implemented.

## Current interaction points

- `terraform output vpc_id`
- `terraform output private_subnet_ids`
- `terraform output public_subnet_ids`
- `terraform output amp_workspace_id`
- `terraform output prediction_queue_url`
- `terraform output audit_table_name`
- `terraform output evidence_bucket_name`
- `terraform output ecs_cluster_name`
- `terraform output service_connect_namespace_name`
- `terraform output telemetry_api_task_definition_arn`

## Mock/E2E note

Full mock E2E through ALB -> API -> SQS -> Worker -> AI -> DynamoDB/S3 is no
longer represented as completed Terraform because Worker, AI, ALB, Scheduler,
Security Groups, and Observability are teammate-owned placeholders.

Keep future smoke tests scoped to whichever assignee-owned resources are present.
