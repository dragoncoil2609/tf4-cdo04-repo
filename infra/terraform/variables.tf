# -----------------------------------------------------------------------------
# CDO-04 Platform -- Input variables
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used in resource naming and tags"
  type        = string
  default     = "tf4-cdo04"
}

variable "environment" {
  description = "Deployment environment (sandbox, staging, prod)"
  type        = string
  default     = "sandbox"

  validation {
    condition     = contains(["sandbox", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: sandbox, staging, prod."
  }
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "At least 2 AZs are required."
  }
}

variable "telemetry_api_image_tag" {
  description = "Docker image tag/URI for the Telemetry API task definition (CPOA-46)"
  type        = string
  default     = "MOCK_PLACEHOLDER_TELEMETRY_API:latest"
}

variable "adot_collector_image_tag" {
  description = "Docker image tag/URI for the ADOT Collector sidecar. Empty uses the public AWS OTEL collector image."
  type        = string
  default     = ""
}

variable "prediction_worker_image_tag" {
  description = "Docker image tag/URI for the Prediction Worker ECS task definition (CPOA-47)"
  type        = string
  default     = "MOCK_PLACEHOLDER_PREDICTION_WORKER:latest"
}

variable "ai_engine_image_tag" {
  description = "Docker image tag/URI for the AI Engine ECS task definition (CPOA-48)"
  type        = string
  default     = "MOCK_PLACEHOLDER_AI_ENGINE:latest"
}

variable "app_port" {
  description = "Application container port used by Telemetry API and AI Engine"
  type        = number
  default     = 8080
}

# TODO (CPOA-40): allowed_ingress_cidrs and security group tuning belong to Security Groups owner.
# TODO (CPOA-78): acm_certificate_arn and deployment pipeline variables belong to CI/CD owner.
# TODO (CPOA-88/CPOA-98): alert_email and budget_limit belong to Observability/Cost owners.

variable "alert_email" {
  description = "SNS notification email for budgets"
  type        = string
  default     = "cdo04-alerts@internal.local"
}

