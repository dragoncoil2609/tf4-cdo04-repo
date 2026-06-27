# -----------------------------------------------------------------------------
# CDO-04 Compute Module -- Input Variables
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Identifiers
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

# -----------------------------------------------------------------------------
# Networking (from networking module)
# -----------------------------------------------------------------------------
variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS services"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID for the public ALB"
  type        = string
}

variable "ecs_api_security_group_id" {
  description = "Security group ID for the Telemetry API ECS tasks"
  type        = string
}

variable "worker_security_group_id" {
  description = "Security group ID for the Prediction Worker ECS tasks"
  type        = string
}

variable "ai_engine_security_group_id" {
  description = "Security group ID for the AI Engine ECS tasks"
  type        = string
}

# -----------------------------------------------------------------------------
# Data layer (from data module)
# -----------------------------------------------------------------------------
variable "prediction_queue_url" {
  description = "SQS prediction queue URL (for task environment injection)"
  type        = string
}

variable "prediction_queue_arn" {
  description = "SQS prediction queue ARN (for IAM policy and EventBridge target)"
  type        = string
}

variable "evidence_bucket_name" {
  description = "S3 evidence bucket name"
  type        = string
}

variable "evidence_kms_key_arn" {
  description = "KMS key ARN for S3 evidence bucket encryption"
  type        = string
}

variable "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint URL (ADOT collector target)"
  type        = string
}

variable "amp_query_endpoint" {
  description = "AMP query endpoint URL (Prediction Worker PromQL)"
  type        = string
}

variable "amp_workspace_arn" {
  description = "AMP workspace ARN (IAM policy scope)"
  type        = string
}

variable "audit_table_name" {
  description = "DynamoDB audit table name"
  type        = string
}

variable "audit_table_arn" {
  description = "DynamoDB audit table ARN"
  type        = string
}

variable "policy_table_name" {
  description = "DynamoDB service policy table name"
  type        = string
}

variable "policy_table_arn" {
  description = "DynamoDB service policy table ARN"
  type        = string
}

variable "baseline_bucket_name" {
  description = "S3 baseline bucket name (AI Engine reads baselines/)"
  type        = string
}

variable "sns_alert_topic_arn" {
  description = "SNS alert topic ARN for high-risk prediction alerts"
  type        = string
}

variable "service_policy_secret_arn" {
  description = "Secrets Manager ARN for service policy config"
  type        = string
}

variable "ai_service_config_secret_arn" {
  description = "Secrets Manager ARN for AI engine service endpoint/config"
  type        = string
}

# -----------------------------------------------------------------------------
# Scheduler DLQ (from data module)
# -----------------------------------------------------------------------------
variable "scheduler_dlq_arn" {
  description = "SQS scheduler target DLQ ARN for EventBridge Scheduler dead-letter config. Omit to skip DLQ."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Container images
# -----------------------------------------------------------------------------
variable "telemetry_api_image_tag" {
  description = "Docker image tag/URI for the Telemetry Ingestion API"
  type        = string
}

variable "prediction_worker_image_tag" {
  description = "Docker image tag/URI for the Prediction Worker"
  type        = string
}

variable "ai_engine_image_tag" {
  description = "Docker image tag/URI for the AI Engine"
  type        = string
}

variable "adot_collector_image_tag" {
  description = "Docker image tag/URI for the ADOT/Prometheus Collector"
  type        = string
}

# -----------------------------------------------------------------------------
# Ingress / Security
# -----------------------------------------------------------------------------
variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the public ALB"
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "allowed_ingress_cidrs must contain at least one CIDR."
  }
}

variable "acm_certificate_arn" {
  description = "ARN of an existing ACM certificate in us-east-1 for HTTPS. Required for non-sandbox environments."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Feature toggle
# -----------------------------------------------------------------------------
variable "enable_services" {
  description = "Whether to create ECS services. Set to false until images are built and pushed to ECR."
  type        = bool
  default     = false
}
