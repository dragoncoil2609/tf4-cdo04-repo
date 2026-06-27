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

# TODO (CPOA-40): allowed_ingress_cidrs and security group tuning belong to Security Groups owner.
# TODO (CPOA-47/CPOA-48): prediction_worker_image_tag and ai_engine_image_tag belong to ECS service owners.
# TODO (CPOA-78): acm_certificate_arn and deployment pipeline variables belong to CI/CD owner.
# TODO (CPOA-88/CPOA-98): alert_email and budget_limit belong to Observability/Cost owners.
