# -----------------------------------------------------------------------------
# Data module -- Input variables
#
# Matches the root module call exactly:
#   project_name, environment, aws_region, vpc_id, private_subnet_ids,
#   allowed_cidrs, alert_email
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

# -----------------------------------------------------------------------------
# Networking context (accepted for interface compatibility;
# data-layer resources are primarily VPC-agnostic at the API level)
# -----------------------------------------------------------------------------
variable "vpc_id" {
  description = "VPC ID (accepted for interface compatibility)"
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (accepted for interface compatibility)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------
variable "allowed_cidrs" {
  description = "CIDR blocks allowed for data-layer access (accepted for future policies)"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# Alerting
# -----------------------------------------------------------------------------
variable "alert_email" {
  description = "Email address for SNS alert subscription. If non-empty, an email subscription is created (requires manual confirmation in AWS Console)."
  type        = string
  default     = ""
}
