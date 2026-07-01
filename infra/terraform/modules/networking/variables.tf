# ----------------------------------------------------------------------------
# CDO-04 Networking Module -- Input Variables
# ----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used in resource naming and tags"
  type        = string
}

variable "environment" {
  description = "Deployment environment (sandbox, staging, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for VPC and networking resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "az_count" {
  description = "Number of availability zones to use (min 2)"
  type        = number

  validation {
    condition     = var.az_count >= 2
    error_message = "At least 2 AZs are required for ALB and ECS service availability."
  }
}
variable "app_port" {
  description = "Application container port used by Telemetry API and AI Engine"
  type        = number
  default     = 8080
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
