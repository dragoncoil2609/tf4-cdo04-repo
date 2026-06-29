# -----------------------------------------------------------------------------
# CDO-04 Platform -- Outputs
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

output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = module.networking.nat_gateway_id
}

output "s3_endpoint_id" {
  description = "VPC Gateway Endpoint ID for S3"
  value       = module.networking.s3_endpoint_id
}

output "dynamodb_endpoint_id" {
  description = "VPC Gateway Endpoint ID for DynamoDB"
  value       = module.networking.dynamodb_endpoint_id
}

output "amp_workspace_id" {
  description = "AMP workspace ID"
  value       = module.data.amp_workspace_id
}

output "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint URL"
  value       = module.data.amp_remote_write_endpoint
}

output "amp_query_endpoint" {
  description = "AMP query endpoint URL"
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

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = module.compute.ecs_cluster_name
}

output "service_connect_namespace_name" {
  description = "ECS Service Connect namespace name"
  value       = module.compute.service_connect_namespace_name
}

output "telemetry_api_task_definition_arn" {
  description = "Telemetry API ECS task definition ARN"
  value       = module.compute.telemetry_api_task_definition_arn
}

# TODO: ALB, ECS service, ECR, scheduler, dashboard, alarm, budget, and SNS
# outputs belong to teammate-owned work and are intentionally placeholders now.
output "alb_sg_id" {
  description = "Security group ID for the public ALB"
  value       = module.networking.alb_sg_id
}

output "telemetry_api_sg_id" {
  description = "Security group ID for the Telemetry API ECS service"
  value       = module.networking.telemetry_api_sg_id
}

output "prediction_worker_sg_id" {
  description = "Security group ID for the Prediction Worker ECS service"
  value       = module.networking.prediction_worker_sg_id
}

output "ai_engine_sg_id" {
  description = "Security group ID for the AI Engine ECS service"
  value       = module.networking.ai_engine_sg_id
}
output "kms_key_arn" {
  description = "Project KMS key ARN"
  value       = module.data.kms_key_arn
}

output "kms_key_alias" {
  description = "Project KMS key alias"
  value       = module.data.kms_key_alias
}

output "ssm_ai_service_name_parameter" {
  description = "SSM parameter name for AI service name"
  value       = module.data.ssm_ai_service_name_parameter
}

output "ssm_ai_predict_path_parameter" {
  description = "SSM parameter name for AI predict path"
  value       = module.data.ssm_ai_predict_path_parameter
}

output "ssm_lookback_window_parameter" {
  description = "SSM parameter name for prediction lookback window"
  value       = module.data.ssm_lookback_window_parameter
}

output "tenant_ingest_token_secret_arn" {
  description = "Secrets Manager ARN for tenant ingest token"
  value       = module.data.tenant_ingest_token_secret_arn
}

output "slack_webhook_secret_arn" {
  description = "Secrets Manager ARN for Slack webhook"
  value       = module.data.slack_webhook_secret_arn
}

output "ai_sigv4_config_secret_arn" {
  description = "Secrets Manager ARN for AI SigV4 config"
  value       = module.data.ai_sigv4_config_secret_arn
}