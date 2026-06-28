# -----------------------------------------------------------------------------
# Bootstrap variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for bootstrap resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in resource naming"
  type        = string
  default     = "tf4-cdo04"
}

variable "environment" {
  description = "Environment name for bootstrap tags"
  type        = string
  default     = "bootstrap"
}

variable "state_bucket_name_prefix" {
  description = "Prefix for S3 state bucket. A random suffix is appended for global uniqueness."
  type        = string
  default     = "tf4-cdo04-terraform-state"
}

variable "tags" {
  description = "Common tags applied to bootstrap resources"
  type        = map(string)
  default = {
    Project     = "tf4-cdo04"
    Environment = "bootstrap"
    ManagedBy   = "terraform"
  }
}

# TODO (CPOA-38): GitHub org/repo/branch variables belong to CI/CD OIDC setup.
