# -----------------------------------------------------------------------------
# CDO-04 Compute Module -- Input Variables
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
  description = "AWS region for all resources"
  type        = string
}

variable "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint URL"
  type        = string
}

variable "amp_workspace_arn" {
  description = "AMP workspace ARN"
  type        = string
}

variable "amp_query_endpoint" {
  description = "AMP query endpoint"
  type        = string
}

variable "prediction_queue_url" {
  description = "SQS prediction queue URL"
  type        = string
}

variable "prediction_queue_arn" {
  description = "SQS prediction queue ARN"
  type        = string
}

variable "telemetry_api_image_tag" {
  description = "Docker image tag/URI for the Telemetry Ingestion API"
  type        = string
}

# TODO (CPOA-40/CPOA-44): add SG, ALB, Scheduler, and additional service variables in assignee-owned work.

variable "vpc_id" {
  description = "VPC ID for ALB placement"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for ALB"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group ID for the public ALB"
  type        = string
}

variable "app_port" {
  description = "Application container port used by Telemetry API and AI Engine"
  type        = number
  default     = 8080
}

variable "ai_engine_image" {
  description = "Container image for AI Engine"
  type        = string
  default     = "MOCK_PLACEHOLDER_AI_ENGINE:latest"
}

variable "ai_engine_sg_id" {
  description = "Security group ID for the AI Engine ECS service"
  type        = string
}

variable "evidence_bucket_name" {
  description = "S3 evidence bucket name for AI Engine baseline access"
  type        = string
}

variable "prediction_queue_name" {
  description = "SQS prediction queue name (for worker env reference)"
  type        = string
}

variable "prediction_queue_dlq_name" {
  description = "SQS prediction DLQ name (for worker env reference)"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ECS tasks"
  type        = list(string)
}

variable "telemetry_api_sg_id" {
  description = "Security group ID for the Telemetry API ECS service"
  type        = string
}

variable "prediction_worker_sg_id" {
  description = "Security group ID for Prediction Worker"
  type        = string
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}

variable "app_log_retention_days" {
  description = "CloudWatch Logs retention for application logs"
  type        = number
  default     = 14
}

variable "prediction_worker_image" {
  description = "Container image for Prediction Worker"
  type        = string

  # Placeholder image for infrastructure validation/demo.
  # Replace with real worker image once application artifact is ready.
  default = "public.ecr.aws/docker/library/python:3.11-slim"
}

variable "prediction_worker_desired_count" {
  description = "Desired count for Prediction Worker ECS service"
  type        = number
  default     = 1
}

variable "prediction_worker_stop_timeout_seconds" {
  description = "Stop timeout for graceful shutdown"
  type        = number
  default     = 30
}

variable "enable_execute_command" {
  description = "Enable ECS Exec"
  type        = bool
  default     = false
}

variable "audit_table_name" {
  description = "DynamoDB audit table name"
  type        = string
}

# Temporary wildcard until data module exposes exact table ARNs.
# Still satisfies worker capability for W12 demo.
variable "worker_dynamodb_table_arns" {
  description = "DynamoDB table ARNs the worker can access"
  type        = list(string)
  default     = ["*"]
}

# Temporary wildcard until Observability/SNS module exposes final topic ARN.
variable "alert_topic_arn" {
  description = "SNS topic ARN for high-risk alerts"
  type        = string
  default     = "*"
}

# Temporary wildcard until data module exposes exact SSM parameter ARNs.
variable "worker_ssm_parameter_arns" {
  description = "SSM parameter ARNs the worker can read"
  type        = list(string)
  default     = ["*"]
}

variable "worker_secret_arns" {
  description = "Secrets Manager secret ARNs the worker can read"
  type        = list(string)
  default     = ["*"]
}

variable "kms_key_arn" {
  description = "KMS key ARN for decrypting config/secrets"
  type        = string
  default     = "*"
}

variable "ai_service_name" {
  description = "AI Engine service name"
  type        = string
  default     = "ai-engine"
}

variable "ai_predict_path" {
  description = "AI predict endpoint path"
  type        = string
  default     = "/v1/predict"
}

variable "lookback_window_minutes" {
  description = "Prediction lookback window in minutes"
  type        = number
  default     = 120
}

variable "ai_sigv4_config_secret_arn" {
  description = "Secrets Manager ARN for AI SigV4 config"
  type        = string
}