# Bootstrap -- CDO-04 Terraform Foundation

Vinh-owned scope: CPOA-37 Terraform backend only.

Creates:
- S3 state bucket
- Versioning
- AES256 encryption
- Block Public Access
- TLS-only bucket policy
- Noncurrent-version lifecycle
- Native Terraform S3 lockfile workflow (`use_lockfile = true`)

Does not create:
- DynamoDB lock table
- GitHub OIDC provider / deploy role (`CPOA-38`, Truong An)

## Quick start

```bash
cd infra/bootstrap
terraform init
terraform plan
terraform apply
```

Copy `backend_config_snippet` into `infra/terraform/backend.tf` and replace `<environment>` with `sandbox`, `staging`, or `prod`.

## State keys

```text
tf4-cdo04/sandbox/terraform.tfstate
tf4-cdo04/staging/terraform.tfstate
tf4-cdo04/prod/terraform.tfstate
```
