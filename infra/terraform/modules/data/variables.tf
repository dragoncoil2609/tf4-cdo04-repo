# -----------------------------------------------------------------------------
# Data module -- Input variables
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used in resource naming and tags"
  type        = string

  validation {
    condition     = length(var.project_name) > 0
    error_message = "project_name must not be empty."
  }
}

variable "environment" {
  description = "Deployment environment (sandbox, staging, prod)"
  type        = string

  validation {
    condition     = contains(["sandbox", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: sandbox, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all data-layer resources"
  type        = string
  default     = "us-east-1"
}
