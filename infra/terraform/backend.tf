# -----------------------------------------------------------------------------
# CDO-04 Terraform Backend -- S3 Remote State
#
# IMPORTANT: Terraform backend blocks CANNOT use variable interpolation.
# This is a documented Terraform limitation (backend is evaluated before
# variables are processed).
#
# CI must pass the environment-specific state key during init:
#
#   terraform init -backend-config="key=tf4-cdo04/<env>/terraform.tfstate"
#
# Valid keys:
#   - tf4-cdo04/sandbox/terraform.tfstate
#   - tf4-cdo04/staging/terraform.tfstate
#   - tf4-cdo04/prod/terraform.tfstate
#
# Bucket and region come from infra/bootstrap outputs and stay static for this
# capstone account. State locking uses Terraform >= 1.10 native S3 lockfile
# (use_lockfile = true). DynamoDB lock table is NOT used.
# -----------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket = "tf4-cdo04-terraform-state-0e0bped4"
    # Default for local sandbox init; CI overrides with -backend-config="key=tf4-cdo04/<env>/terraform.tfstate".
    key          = "tf4-cdo04/sandbox/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}