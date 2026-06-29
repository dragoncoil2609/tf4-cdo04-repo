# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Input Variables
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used in resource naming and tags"
  type        = string
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
  description = "AWS region for observability resources"
  type        = string
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}

variable "alert_email" {
  description = "Email endpoint for budget/cost alerts"
  type        = string
  default     = "cdo04-alerts@internal.local"
}

variable "ecs_cluster_name" {
  description = "ECS cluster name used by the cost breaker Lambda"
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ECS cluster ARN used by the cost breaker Lambda"
  type        = string
}

variable "ai_service_name" {
  description = "AI Engine ECS service name"
  type        = string
}

variable "worker_service_name" {
  description = "Prediction Worker ECS service name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS Key ARN for CloudWatch Logs encryption"
  type        = string
}
