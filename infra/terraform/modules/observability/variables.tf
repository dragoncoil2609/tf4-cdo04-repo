# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Input variables
#
# Must match the root module call signature exactly.
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used in resource naming and tags"
  type        = string
}

variable "environment" {
  description = "Deployment environment (sandbox, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

# -----------------------------------------------------------------------------
# Compute targets to monitor
# -----------------------------------------------------------------------------
variable "ecs_cluster_name" {
  description = "ECS cluster name for CloudWatch metric dimensions"
  type        = string
}

variable "telemetry_api_service_name" {
  description = "ECS service name for Telemetry Ingestion API"
  type        = string
}

variable "prediction_worker_service_name" {
  description = "ECS service name for Prediction Worker"
  type        = string
}

variable "ai_engine_service_name" {
  description = "ECS service name for AI Engine"
  type        = string
}

variable "adot_collector_service_name" {
  description = "ECS service name for ADOT/Prometheus Collector"
  type        = string
}

variable "alb_arn" {
  description = "ALB ARN (parsed to extract LoadBalancer dimension)"
  type        = string
}

variable "alb_target_group_arn" {
  description = "ALB target group ARN (parsed to extract TargetGroup dimension)"
  type        = string
}

# -----------------------------------------------------------------------------
# Data layer targets to monitor
# -----------------------------------------------------------------------------
variable "prediction_queue_url" {
  description = "SQS prediction queue URL (parsed to extract QueueName dimension)"
  type        = string
}

variable "prediction_queue_dlq_url" {
  description = "SQS prediction DLQ URL (parsed to extract QueueName dimension)"
  type        = string
}

variable "audit_table_name" {
  description = "DynamoDB audit table name for metric dimensions"
  type        = string
}

variable "amp_workspace_arn" {
  description = "AMP workspace ARN (displayed on dashboard; AMP metrics flow through ADOT)"
  type        = string
}

# -----------------------------------------------------------------------------
# Alerting
# -----------------------------------------------------------------------------
variable "alert_email" {
  description = "Email address for alarm actions and budget subscriber"
  type        = string
  default     = ""
}

variable "budget_limit" {
  description = "Monthly budget limit in USD for AWS Budget alert"
  type        = number
  default     = 200
}
