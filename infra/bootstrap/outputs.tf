# -----------------------------------------------------------------------------
# Bootstrap outputs
# -----------------------------------------------------------------------------

output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform remote state"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket for Terraform remote state"
  value       = aws_s3_bucket.terraform_state.arn
}

output "state_bucket_region" {
  description = "AWS region of the state bucket"
  value       = data.aws_region.current.region
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC IAM provider"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "terraform_deploy_role_arn" {
  description = "ARN of the Terraform deploy role for GitHub Actions"
  value       = aws_iam_role.terraform_deploy.arn
}

output "terraform_deploy_role_name" {
  description = "Name of the Terraform deploy role for GitHub Actions"
  value       = aws_iam_role.terraform_deploy.name
}

output "backend_config_snippet" {
  description = "Terraform backend configuration block ready to copy into infra/terraform/backend.tf"
  value       = <<-EOT

  # Insert this backend block into infra/terraform/backend.tf.
  # Replace <environment> with sandbox, staging, or prod.
  #
  # State locking uses Terraform >= 1.10 native S3 lockfile (use_lockfile = true).
  # No DynamoDB lock table is needed.
  #
  # Note: AWS provider region for the backend must match the state bucket region.

  terraform {
    backend "s3" {
      bucket       = "${aws_s3_bucket.terraform_state.id}"
      key          = "tf4-cdo04/<environment>/terraform.tfstate"
      region       = "${data.aws_region.current.region}"
      encrypt      = true
      use_lockfile = true
    }
  }
  EOT
}

# -----------------------------------------------------------------------------
# Internal data sources
# -----------------------------------------------------------------------------
data "aws_region" "current" {}
