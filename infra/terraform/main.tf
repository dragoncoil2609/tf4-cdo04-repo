# -----------------------------------------------------------------------------
# CDO-04 Platform -- Main Terraform Root
#
# Nguyễn Thành Vinh-owned IaC slice only:
#   - CPOA-39: Networking module
#   - CPOA-42: Data module foundation
#   - CPOA-41: ECS Cluster + Service Connect namespace
#   - CPOA-46: Telemetry API task definition
#   - CPOA-50: ECS autoscaling placeholder
# -----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count
}

module "data" {
  source = "./modules/data"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  tags         = local.common_tags
}

module "compute" {
  source = "./modules/compute"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  tags         = local.common_tags

  amp_remote_write_endpoint = module.data.amp_remote_write_endpoint
  amp_workspace_arn         = module.data.amp_workspace_arn
  amp_query_endpoint        = module.data.amp_query_endpoint

  prediction_queue_url = module.data.prediction_queue_url
  prediction_queue_arn = module.data.prediction_queue_arn

  telemetry_api_image_tag = var.telemetry_api_image_tag

  private_subnet_ids      = module.networking.private_subnet_ids
  telemetry_api_sg_id     = module.networking.telemetry_api_sg_id
  prediction_worker_sg_id = module.networking.prediction_worker_sg_id

  audit_table_name = module.data.audit_table_name

  kms_key_arn = module.data.kms_key_arn

  worker_secret_arns = [
    module.data.ai_sigv4_config_secret_arn,
    module.data.tenant_ingest_token_secret_arn,
    module.data.slack_webhook_secret_arn
  ]

  ai_sigv4_config_secret_arn = module.data.ai_sigv4_config_secret_arn

  ai_service_name         = "ai-engine"
  ai_predict_path         = "/v1/predict"
  lookback_window_minutes = 120
}

# -----------------------------------------------------------------------------
# TODO (CPOA-40): Security Groups module -- owned by Truong An.
# TODO (CPOA-44): EventBridge Scheduler -- owned by Truong An.
# TODO (CPOA-47/CPOA-48/CPOA-49/CPOA-51): Worker/AI task definitions,
# Service Connect AI route, and AI baseline S3 access -- owned by Truong An.
# TODO (CPOA-78): CI/CD & Deployment -- owned by Nguyen Huy Hoang.
# TODO (CPOA-88): Observability & Testing -- owned by Nguyen Quach Khang Ninh.
# TODO (CPOA-98): Cost & Operations -- owned by Huy Tạ Hoàng.
# -----------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  tags         = local.common_tags
}