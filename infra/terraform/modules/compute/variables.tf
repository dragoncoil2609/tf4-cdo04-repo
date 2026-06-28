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

# TODO (CPOA-40/CPOA-47/CPOA-48/CPOA-49/CPOA-44): add SG, Worker, AI,
# Service Connect, ALB, Scheduler, and service variables in assignee-owned work.

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ECS tasks"
  type        = list(string)
}

variable "telemetry_api_sg_id" {
  description = "Security group ID for the Telemetry API ECS service"
  type        = string
}

