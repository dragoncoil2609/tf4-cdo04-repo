# -----------------------------------------------------------------------------
# CDO-04 Platform -- Outputs
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.networking.public_subnet_ids
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------
output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.compute.ecs_cluster_name
}

output "alb_dns_name" {
  description = "Public ALB DNS name for telemetry ingestion"
  value       = module.compute.alb_dns_name
}

output "alb_arn" {
  description = "Public ALB ARN"
  value       = module.compute.alb_arn
}

output "telemetry_api_service_name" {
  description = "ECS service name for Telemetry Ingestion API"
  value       = module.compute.telemetry_api_service_name
}

output "prediction_worker_service_name" {
  description = "ECS service name for Prediction Worker"
  value       = module.compute.prediction_worker_service_name
}

output "ai_engine_service_name" {
  description = "ECS service name for AI Engine"
  value       = module.compute.ai_engine_service_name
}

output "adot_collector_service_name" {
  description = "ECS service name for ADOT/Prometheus Collector"
  value       = module.compute.adot_collector_service_name
}

output "telemetry_api_ecr_repository_url" {
  description = "ECR repository URL for Telemetry API"
  value       = module.compute.telemetry_api_ecr_repository_url
}

output "prediction_worker_ecr_repository_url" {
  description = "ECR repository URL for Prediction Worker"
  value       = module.compute.prediction_worker_ecr_repository_url
}

output "ai_engine_ecr_repository_url" {
  description = "ECR repository URL for AI Engine"
  value       = module.compute.ai_engine_ecr_repository_url
}

# -----------------------------------------------------------------------------
# Data
# -----------------------------------------------------------------------------
output "amp_workspace_id" {
  description = "AMP workspace ID for metric ingestion and query"
  value       = module.data.amp_workspace_id
}

output "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint URL"
  value       = module.data.amp_remote_write_endpoint
}

output "amp_query_endpoint" {
  description = "AMP query endpoint URL (used by Prediction Worker)"
  value       = module.data.amp_query_endpoint
}

output "prediction_queue_url" {
  description = "SQS prediction queue URL"
  value       = module.data.prediction_queue_url
}

output "prediction_queue_dlq_url" {
  description = "SQS prediction DLQ URL"
  value       = module.data.prediction_queue_dlq_url
}

output "audit_table_name" {
  description = "DynamoDB audit table name"
  value       = module.data.audit_table_name
}

output "evidence_bucket_name" {
  description = "S3 evidence bucket name"
  value       = module.data.evidence_bucket_name
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------
output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = module.observability.dashboard_url
}

output "alarm_arns" {
  description = "List of CloudWatch alarm ARNs"
  value       = module.observability.alarm_arns
}

output "sns_alert_topic_arn" {
  description = "SNS alert topic ARN"
  value       = module.data.sns_alert_topic_arn
}
