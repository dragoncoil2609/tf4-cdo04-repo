# -----------------------------------------------------------------------------
# CDO-04 Platform -- Main Terraform Root
#
# Wires together the four infrastructure modules:
#   networking   - VPC, subnets, security groups, NAT, gateway endpoints
#   data         - AMP, DynamoDB, SQS/DLQs, S3 evidence, secrets/KMS
#   compute      - ALB, ECS cluster/services, ECS Service Connect, EventBridge Scheduler
#   observability - CloudWatch logs/metrics/dashboard/alarms, SNS, budget
#
# Provider config applies common tags across all taggable resources.
# Environment-specific values come from variables / tfvars.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# AWS provider (us-east-1)
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# -----------------------------------------------------------------------------
# Local values
# -----------------------------------------------------------------------------
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Application container images.
  # Defaults use a safe mock placeholder that prevents ECS from trying to
  # pull a real image before CI has pushed one.
  # Override in terraform.tfvars with real ECR URIs or replace with module-agent outputs.
  container_images = {
    telemetry_api     = var.telemetry_api_image_tag
    prediction_worker = var.prediction_worker_image_tag
    ai_engine         = var.ai_engine_image_tag
    adot_collector    = var.adot_collector_image_tag
  }
}

# -----------------------------------------------------------------------------
# Module: networking
# -----------------------------------------------------------------------------
# Creates VPC with public/private subnets, 1 zonal NAT Gateway,
# S3 and DynamoDB Gateway VPC Endpoints, and security groups.
#
# Expected outputs from modules/networking:
#   vpc_id
#   public_subnet_ids
#   private_subnet_ids
#   nat_gateway_id
#   s3_endpoint_id
#   dynamodb_endpoint_id
#   alb_security_group_id
#   ecs_api_security_group_id
#   worker_security_group_id
#   ai_engine_security_group_id
module "networking" {
  source = "./modules/networking"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region
  vpc_cidr     = var.vpc_cidr
  az_count     = var.az_count
}

# -----------------------------------------------------------------------------
# Module: data
# -----------------------------------------------------------------------------
# Creates AMP workspace, DynamoDB audit/policy tables, SQS source queue + DLQs,
# S3 evidence/baseline bucket (KMS encrypted), Secrets Manager, and KMS keys.
#
# Expected outputs from modules/data:
#   amp_workspace_id
#   amp_workspace_arn
#   amp_remote_write_endpoint
#   amp_query_endpoint
#   audit_table_name
#   audit_table_arn
#   policy_table_name
#   prediction_queue_url
#   prediction_queue_arn
#   prediction_queue_dlq_url
#   prediction_queue_dlq_arn
#   evidence_bucket_name
#   evidence_bucket_arn
#   evidence_kms_key_arn
#   baseline_bucket_name (may be same as evidence)
#   sns_alert_topic_arn
#   service_policy_secret_arn
#   ai_service_config_secret_arn
module "data" {
  source = "./modules/data"

  project_name       = var.project_name
  environment        = var.environment
  aws_region         = var.aws_region
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  allowed_cidrs      = var.allowed_ingress_cidrs
  alert_email        = var.alert_email
}

# -----------------------------------------------------------------------------
# Module: compute
# -----------------------------------------------------------------------------
# Creates ECR repositories, ECS cluster, ECS Fargate services
# (Telemetry API, Prediction Worker, AI Engine, ADOT Collector),
# public ALB for /v1/ingest, ECS Service Connect for Worker -> AI,
# and EventBridge Scheduler for prediction jobs.
#
# Expected outputs from modules/compute:
#   ecs_cluster_name
#   ecs_cluster_arn
#   alb_dns_name
#   alb_arn
#   alb_target_group_arn
#   telemetry_api_service_name
#   prediction_worker_service_name
#   ai_engine_service_name
#   adot_collector_service_name
#   prediction_scheduler_arn
#
# Expected inputs from modules/networking:
#   vpc_id
#   public_subnet_ids
#   private_subnet_ids
#   alb_security_group_id
#   ecs_api_security_group_id
#   worker_security_group_id
#   ai_engine_security_group_id
#
# Expected inputs from modules/data:
#   prediction_queue_url
#   prediction_queue_arn
#   evidence_bucket_name
#   evidence_kms_key_arn
#   amp_remote_write_endpoint
#   amp_query_endpoint
#   amp_workspace_arn
#   audit_table_name
#   policy_table_name
#   baseline_bucket_name
#   sns_alert_topic_arn
#   service_policy_secret_arn
#   ai_service_config_secret_arn
module "compute" {
  source = "./modules/compute"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  # Networking
  vpc_id                      = module.networking.vpc_id
  public_subnet_ids           = module.networking.public_subnet_ids
  private_subnet_ids          = module.networking.private_subnet_ids
  alb_security_group_id       = module.networking.alb_security_group_id
  ecs_api_security_group_id   = module.networking.ecs_api_security_group_id
  worker_security_group_id    = module.networking.worker_security_group_id
  ai_engine_security_group_id = module.networking.ai_engine_security_group_id

  # Data layer
  prediction_queue_url         = module.data.prediction_queue_url
  prediction_queue_arn         = module.data.prediction_queue_arn
  scheduler_dlq_arn            = module.data.scheduler_dlq_arn
  evidence_bucket_name         = module.data.evidence_bucket_name
  evidence_kms_key_arn         = module.data.evidence_kms_key_arn
  amp_remote_write_endpoint    = module.data.amp_remote_write_endpoint
  amp_query_endpoint           = module.data.amp_query_endpoint
  amp_workspace_arn            = module.data.amp_workspace_arn
  audit_table_name             = module.data.audit_table_name
  policy_table_name            = module.data.policy_table_name
  baseline_bucket_name         = module.data.baseline_bucket_name
  sns_alert_topic_arn          = module.data.sns_alert_topic_arn
  service_policy_secret_arn    = module.data.service_policy_secret_arn
  ai_service_config_secret_arn = module.data.ai_service_config_secret_arn

  # Container images
  telemetry_api_image_tag     = local.container_images.telemetry_api
  prediction_worker_image_tag = local.container_images.prediction_worker
  ai_engine_image_tag         = local.container_images.ai_engine
  adot_collector_image_tag    = local.container_images.adot_collector

  # Ingress
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  acm_certificate_arn   = var.acm_certificate_arn

  # Toggle: enable services only after images are built and pushed
  enable_services = var.enable_services
}

# -----------------------------------------------------------------------------
# Module: observability
# -----------------------------------------------------------------------------
# Creates CloudWatch log groups (with retention), CloudWatch alarms
# (ALB 5xx/latency/unhealthy hosts, ECS CPU/Memory, SQS queue depth/DLQ depth/age,
# DynamoDB throttles/system errors), CloudWatch dashboard, SNS topic, AWS Budget
#
# Expected outputs from modules/observability:
#   dashboard_url
#   alarm_arns
#   sns_alert_topic_arn (if SNS is created here instead of data module)
#
# Expected inputs from modules/compute:
#   ecs_cluster_name, telemetry_api_service_name, etc.
#   alb_arn, alb_target_group_arn
#
# Expected inputs from modules/data:
#   prediction_queue_url, prediction_queue_dlq_url
#   audit_table_name, amp_workspace_arn
module "observability" {
  source = "./modules/observability"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  # Compute targets to monitor
  ecs_cluster_name               = module.compute.ecs_cluster_name
  telemetry_api_service_name     = module.compute.telemetry_api_service_name
  prediction_worker_service_name = module.compute.prediction_worker_service_name
  ai_engine_service_name         = module.compute.ai_engine_service_name
  adot_collector_service_name    = module.compute.adot_collector_service_name
  alb_arn                        = module.compute.alb_arn
  alb_target_group_arn           = module.compute.alb_target_group_arn

  # Data layer to monitor
  prediction_queue_url     = module.data.prediction_queue_url
  prediction_queue_dlq_url = module.data.prediction_queue_dlq_url
  audit_table_name         = module.data.audit_table_name
  amp_workspace_arn        = module.data.amp_workspace_arn

  # Alerting
  alert_email  = var.alert_email
  budget_limit = var.budget_limit
}
