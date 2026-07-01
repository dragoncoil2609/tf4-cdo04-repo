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
  default     = "ngonguyentruongan2907@gmail.com"
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

# -----------------------------------------------------------------------------
# Operational alarm inputs (CPOA-88 observability wiring)
# -----------------------------------------------------------------------------

variable "telemetry_api_service_name" {
  description = "ECS service name for the Telemetry API (CloudWatch dimensions)"
  type        = string
}

variable "ai_engine_service_name" {
  description = "ECS service name for the AI Engine (CloudWatch dimensions)"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch dimensions (empty if ALB not yet deployed)"
  type        = string
  default     = ""
}

variable "telemetry_api_target_group_arn_suffix" {
  description = "Target group ARN suffix for ALB CloudWatch dimensions (empty if not yet deployed)"
  type        = string
  default     = ""
}

variable "ai_engine_target_group_arn_suffix" {
  description = "AI Engine target group ARN suffix for ALB CloudWatch dimensions (empty if not yet deployed)"
  type        = string
  default     = ""
}

variable "prediction_queue_name" {
  description = "SQS prediction queue name (CloudWatch dimension)"
  type        = string
}

variable "prediction_queue_dlq_name" {
  description = "SQS prediction DLQ name (CloudWatch dimension)"
  type        = string
}

variable "telemetry_api_alb_p99_scale_out_policy_arn" {
  description = "Step scaling policy ARN for ALB p99 scale-out (empty if not yet deployed)"
  type        = string
  default     = ""
}

variable "prediction_worker_scale_out_policy_arn" {
  description = "Step scaling policy ARN for prediction worker scale-out (empty if not yet deployed)"
  type        = string
  default     = ""
}

variable "prediction_worker_scale_in_policy_arn" {
  description = "Step scaling policy ARN for prediction worker scale-in (empty if not yet deployed)"
  type        = string
  default     = ""
}

variable "ai_engine_latency_scale_out_policy_arn" {
  description = "Step scaling policy ARN for AI Engine latency scale-out (empty if not yet deployed)"
  type        = string
  default     = ""
}

variable "kms_key_arn" {
  description = "KMS Key ARN for CloudWatch Logs encryption"
  type        = string
}

# =============================================================================
# Khai báo các biến phục vụ bộ khung Dashboard & Alarms (CPOA-89/90)
# =============================================================================

variable "runbook_url" {
  description = "URL link tới tài liệu hướng dẫn vận hành SRE khi có cảnh báo kích hoạt"
  type        = string
  default     = "https://github.com/dragoncoil2609/tf4-cdo04-repo/blob/main/docs/misc/cost_guard_runbook.md"
}