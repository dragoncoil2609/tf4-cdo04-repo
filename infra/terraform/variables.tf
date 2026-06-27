# -----------------------------------------------------------------------------
# CDO-04 Platform -- Input variables
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Required identifiers
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

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
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
    error_message = "At least 2 AZs are required for ALB and ECS service availability."
  }
}

# -----------------------------------------------------------------------------
# Security / Ingress
# -----------------------------------------------------------------------------
variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the public ALB (NO default -- must be explicit)"
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "allowed_ingress_cidrs must contain at least one CIDR. Do NOT use 0.0.0.0/0 in production."
  }
}

variable "acm_certificate_arn" {
  description = "ARN of an existing ACM certificate in us-east-1 for HTTPS. Required for non-sandbox environments. Optional for sandbox (HTTP-only allowed)."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Container images
# -----------------------------------------------------------------------------
# Defaults use safe placeholders.
# ADOT default is empty: the compute module falls back to the public ADOT image.
# or set per environment in terraform.tfvars.
#
# All services share a minimal mock-safe placeholder until CI pushes real images.
# Change the placeholder to a NOOP image or your CI-produced ECR URI.

variable "telemetry_api_image_tag" {
  description = "Docker image tag/URI for the Telemetry Ingestion API (e.g. <ecr-repo-url>:<tag>)"
  type        = string
  default     = "MOCK_PLACEHOLDER_TELEMETRY_API:latest"
}

variable "prediction_worker_image_tag" {
  description = "Docker image tag/URI for the Prediction Worker"
  type        = string
  default     = "MOCK_PLACEHOLDER_PREDICTION_WORKER:latest"
}

variable "ai_engine_image_tag" {
  description = "Docker image tag/URI for the AI Engine (ECS Fargate, min 2 tasks)"
  type        = string
  default     = "MOCK_PLACEHOLDER_AI_ENGINE:latest"
}

variable "adot_collector_image_tag" {
  description = "Docker image tag/URI for the ADOT/Prometheus Collector"
  type        = string
  default     = "" # Empty triggers module fallback to public ADOT image
}

# -----------------------------------------------------------------------------
# Feature toggles
# -----------------------------------------------------------------------------
variable "enable_services" {
  description = "Whether to create ECS services. Set to false until images are built and pushed to ECR."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Alerting
# -----------------------------------------------------------------------------
variable "alert_email" {
  description = "Email address for SNS alert subscriptions (optional; subscription must be confirmed manually)"
  type        = string
  default     = ""
}

variable "budget_limit" {
  description = "Monthly budget limit in USD for AWS Budget alarm"
  type        = number
  default     = 200
}
