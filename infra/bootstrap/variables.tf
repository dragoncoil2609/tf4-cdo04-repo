# -----------------------------------------------------------------------------
# Bootstrap variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all bootstrap resources (state bucket, OIDC provider, IAM)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in resource naming (e.g. tf4-cdo04)"
  type        = string
  default     = "tf4-cdo04"
}

variable "environment" {
  description = "Environment name (bootstrap is account-level; use 'bootstrap' or 'shared')"
  type        = string
  default     = "bootstrap"
}

variable "state_bucket_name_prefix" {
  description = "Prefix for the S3 state bucket. A random suffix is appended for global uniqueness."
  type        = string
  default     = "tf4-cdo04-terraform-state"
}

variable "github_org" {
  description = "GitHub organization that owns the repository"
  type        = string
  default     = "pho-veteran"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "tf4-cdo04-repo"
}

variable "github_branch" {
  description = "GitHub branch allowed to assume the deploy role. Use 'main' or a specific branch name."
  type        = string
  default     = "main"
}

variable "tags" {
  description = "Common tags applied to all bootstrap resources"
  type        = map(string)
  default = {
    Project     = "tf4-cdo04"
    Environment = "bootstrap"
    ManagedBy   = "terraform"
  }
}
