# -----------------------------------------------------------------------------
# CDO-04 Terraform Backend -- S3 Remote State
#
# IMPORTANT: Terraform backend blocks CANNOT use variable interpolation.
# This is a documented Terraform limitation (backend is evaluated before
# variables are processed).
#
# YOU MUST EDIT THIS FILE BEFORE RUNNING `terraform init`.
#
# Fill in the values produced by `infra/bootstrap/` outputs:
#   - bucket: state_bucket_name from bootstrap output
#   - region: state_bucket_region from bootstrap output
#   - key: set <environment> to sandbox, staging, or prod
#
# State locking uses Terraform >= 1.10 native S3 lockfile (use_lockfile = true).
# DynamoDB lock table is NOT used (deprecated per AWS/Terraform guidance).
#
# Alternatively, use partial configuration with a backend-config file:
#   terraform init -backend-config="environment=sandbox"
# -----------------------------------------------------------------------------

terraform {
  backend "s3" {
    bucket       = "tf4-cdo04-terraform-state-0e0bped4"
    key          = "tf4-cdo04/sandbox/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}