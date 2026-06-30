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

variable "adot_collector_image_tag" {
  description = "Docker image tag/URI for the ADOT Collector sidecar. Empty uses the public AWS OTEL collector image."
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
  default     = "public.ecr.aws/docker/library/python:3.11-slim"
}

variable "ai_engine_sg_id" {
  description = "Security group ID for the AI Engine ECS service"
  type        = string
}

variable "evidence_bucket_name" {
  description = "S3 evidence bucket name for AI Engine baseline access"
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

variable "worker_dynamodb_table_arns" {
  description = "DynamoDB audit table ARN the worker can write"
  type        = list(string)
}

variable "policy_table_name" {
  description = "DynamoDB service-policy table name"
  type        = string
}

variable "policy_table_arn" {
  description = "DynamoDB service-policy table ARN"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for AI Engine baseline decrypt"
  type        = string
}

# -----------------------------------------------------------------------------
# AI Engine variables -- CDO-W12-011
# -----------------------------------------------------------------------------

variable "ai_engine_desired_count" {
  description = "Desired count for AI Engine ECS service"
  type        = number
  default     = 2
}

variable "ai_engine_min_capacity" {
  description = "Minimum autoscaling capacity for AI Engine"
  type        = number
  default     = 2
}

variable "ai_engine_max_capacity" {
  description = "Maximum autoscaling capacity for AI Engine"
  type        = number
  default     = 4
}

variable "ai_engine_autoscale_cpu_target" {
  description = "Target CPU utilization for AI Engine autoscaling"
  type        = number
  default     = 70
}

variable "baseline_s3_bucket_name" {
  description = "S3 bucket name that stores AI baseline files"
  type        = string
}

variable "baseline_s3_prefix" {
  description = "S3 prefix that stores AI baseline files"
  type        = string
  default     = "baselines/"
}

variable "ai_engine_ssm_parameter_arns" {
  description = "SSM parameter ARNs the AI Engine can read"
  type        = list(string)
  default     = ["*"]
}

variable "ai_engine_secret_arns" {
  description = "Secrets Manager secret ARNs the AI Engine can read"
  type        = list(string)
  default     = ["*"]
}