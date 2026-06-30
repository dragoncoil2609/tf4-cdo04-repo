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

  telemetry_api_image_tag  = var.telemetry_api_image_tag
  adot_collector_image_tag = var.adot_collector_image_tag

  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  alb_sg_id         = module.networking.alb_sg_id

  app_port                = var.app_port
  prediction_worker_image = var.prediction_worker_image_tag
  ai_engine_image         = var.ai_engine_image_tag
  ai_engine_sg_id         = module.networking.ai_engine_sg_id
  evidence_bucket_name    = module.data.evidence_bucket_name

  private_subnet_ids      = module.networking.private_subnet_ids
  telemetry_api_sg_id     = module.networking.telemetry_api_sg_id
  prediction_worker_sg_id = module.networking.prediction_worker_sg_id

  audit_table_name = module.data.audit_table_name
  worker_dynamodb_table_arns = [
    module.data.audit_table_arn
  ]

  kms_key_arn = module.data.kms_key_arn

  baseline_s3_bucket_name = module.data.evidence_bucket_name
  baseline_s3_prefix      = "baselines/"

  ai_engine_secret_arns = [
    module.data.ai_sigv4_config_secret_arn
  ]

  ai_engine_desired_count        = 2
  ai_engine_min_capacity         = 2
  ai_engine_max_capacity         = 4
  ai_engine_autoscale_cpu_target = 70
}


# -----------------------------------------------------------------------------
# TODO (CPOA-40): Security Groups module -- owned by Truong An.
# TODO (CPOA-44): EventBridge Scheduler -- owned by Truong An.
# TODO (CPOA-78): CI/CD & Deployment -- owned by Nguyen Huy Hoang.
# TODO (CPOA-88): Observability & Testing -- owned by Nguyen Quach Khang Ninh.
# TODO (CPOA-98): Cost & Operations -- owned by Huy Tạ Hoàng.
# -----------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"

  project_name        = var.project_name
  environment         = var.environment
  aws_region          = var.aws_region
  tags                = local.common_tags
  ecs_cluster_name    = module.compute.ecs_cluster_name
  ecs_cluster_arn     = module.compute.ecs_cluster_arn
  ai_service_name     = "${var.project_name}-${var.environment}-ai-engine"
  worker_service_name = "${var.project_name}-${var.environment}-prediction-worker"
  alert_email         = var.alert_email

  telemetry_api_service_name = module.compute.telemetry_api_service_name
  ai_engine_service_name     = module.compute.ai_service_name

  alb_arn_suffix                        = module.compute.alb_arn_suffix
  telemetry_api_target_group_arn_suffix = module.compute.telemetry_api_target_group_arn_suffix

  prediction_queue_name     = module.data.prediction_queue_name
  prediction_queue_dlq_name = module.data.prediction_queue_dlq_name

  telemetry_api_alb_p99_scale_out_policy_arn = module.compute.telemetry_api_alb_p99_step_policy_arn
  prediction_worker_scale_out_policy_arn     = module.compute.prediction_worker_scale_out_policy_arn
  prediction_worker_scale_in_policy_arn      = module.compute.prediction_worker_scale_in_policy_arn
  ai_engine_latency_scale_out_policy_arn     = module.compute.ai_engine_latency_step_policy_arn
  kms_key_arn                                = module.data.kms_key_arn
}
