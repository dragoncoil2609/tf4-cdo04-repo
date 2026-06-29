# -----------------------------------------------------------------------------
# Observability module variables
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ECS cluster ARN"
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

variable "alert_email" {
  description = "Alert email address for budget notifications"
  type        = string
  default     = "cdo04-alerts@internal.local"
}
