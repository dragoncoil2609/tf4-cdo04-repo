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
