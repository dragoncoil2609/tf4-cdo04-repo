# Bootstrap -- CDO-04 Terraform Foundation

One-time setup that creates the S3 state backend, GitHub OIDC provider, and a
minimal Terraform deploy role for CI/CD. State locking uses Terraform >= 1.10
native S3 lockfile (`use_lockfile = true`). No DynamoDB lock table is created.

All bootstrap resources deploy to **us-east-1** by default. Override `aws_region`
if a different region is required.

## Prerequisites

- AWS credentials configured (profile or env vars) with permission to create
  S3 buckets and IAM resources.
- Terraform >= 1.10 installed.
- GitHub org/repo known for OIDC trust.

## Quick start

```bash
cd infra/bootstrap
terraform init
terraform plan
terraform apply
```

Override variables as needed:

```bash
terraform apply -var="github_org=my-org" -var="github_repo=my-repo"
```

To deploy bootstrap in a different region:

```bash
terraform apply -var="aws_region=eu-west-1"
```

## State locking

Terraform >= 1.10 supports native S3 lockfile (`use_lockfile = true`), which
is the AWS-recommended approach. DynamoDB-based state locking is deprecated
and is NOT created by this bootstrap.

The backend config snippet output includes `use_lockfile = true` by default.

## Backend config for main root

After bootstrap is applied, copy the `backend_config_snippet` output into
`infra/terraform/backend.tf`, replacing `<environment>` with `sandbox`,
`staging`, or `prod`.

Each environment uses a separate state key:

```
tf4-cdo04/sandbox/terraform.tfstate
tf4-cdo04/staging/terraform.tfstate
tf4-cdo04/prod/terraform.tfstate
```

## GitHub OIDC

The OIDC provider trusts `token.actions.githubusercontent.com` for the
configured GitHub org/repo. The `terraform-deploy` role is the role that
GitHub Actions uses to run `terraform plan` and `terraform apply`.

Trust policy is least-privilege:
- Exact repository restriction via `repo:org/repo:ref:refs/heads/<branch>`
- Explicit audience condition `aud = sts.amazonaws.com` (prevents cross-audience confusion)
- Branch can be narrowed per environment via `github_branch` variable

The minimal deploy policy includes only:
- S3 state bucket read/write/list/delete (for state + lockfile)
- sts:GetCallerIdentity (required for assume-role + AWS provider)

Additional resource provisioning permissions (ECS, ALB, VPC, etc.) are
managed by the main Terraform root's CI/CD pipeline, which can attach
additional inline policies to this role as needed.

## Destroy

```bash
terraform destroy   # only after removing all state objects first
```
