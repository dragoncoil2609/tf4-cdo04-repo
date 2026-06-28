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
variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}

variable "ai_service_name" {
  description = "ECS Service Connect service name for AI Engine"
  type        = string
  default     = "ai-engine"
}

variable "ai_predict_path" {
  description = "AI prediction endpoint path"
  type        = string
  default     = "/v1/predict"
}

variable "lookback_window_minutes" {
  description = "Default lookback window for Prediction Worker PromQL query"
  type        = number
  default     = 120
}

variable "baseline_s3_prefix" {
  description = "S3 prefix for AI Engine baseline files"
  type        = string
  default     = "baselines/"
}