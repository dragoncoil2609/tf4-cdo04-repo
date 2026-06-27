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

output "backend_config_snippet" {
  description = "Terraform backend configuration block ready to copy into infra/terraform/backend.tf"
  value       = <<-EOT

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

# TODO (CPOA-38): OIDC provider and deploy role outputs belong to CI/CD owner.

data "aws_region" "current" {}
