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

output "policy_table_name" {
  description = "DynamoDB service-policy table name"
  value       = module.data.policy_table_name
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

output "alb_dns_name" {
  description = "ALB public DNS name"
  value       = module.compute.alb_dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID"
  value       = module.compute.alb_zone_id
}

output "alb_listener_arn" {
  description = "ALB HTTP listener ARN"
  value       = module.compute.alb_listener_arn
}

output "acm_certificate_arn" {
  description = "ACM SSL certificate ARN"
  value       = module.compute.acm_certificate_arn
}

output "acm_validation_dns_records" {
  description = "CNAME records to create on Name.com for DNS validation"
  value = [
    for dvo in module.compute.acm_domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ]
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
output "eventbridge_scheduler_role_arn" {
  description = "IAM role ARN used by EventBridge Scheduler"
  value       = module.data.eventbridge_scheduler_role_arn
}

output "prediction_schedule_group_name" {
  description = "EventBridge Scheduler group name for prediction jobs"
  value       = module.data.prediction_schedule_group_name
}

output "prediction_schedule_names" {
  description = "EventBridge Scheduler names for demo service prediction jobs"
  value       = module.data.prediction_schedule_names
}
output "prediction_worker_task_definition_arn" {
  description = "Prediction Worker ECS task definition ARN"
  value       = module.compute.prediction_worker_task_definition_arn
}

output "prediction_worker_task_role_arn" {
  description = "Prediction Worker ECS task role ARN"
  value       = module.compute.prediction_worker_task_role_arn
}

output "prediction_worker_service_name" {
  description = "Prediction Worker ECS service name"
  value       = module.compute.prediction_worker_service_name
}

output "prediction_worker_log_group_name" {
  description = "CloudWatch log group for Prediction Worker"
  value       = module.compute.prediction_worker_log_group_name
}
output "telemetry_api_service_name" {
  description = "Telemetry API ECS service name"
  value       = module.compute.telemetry_api_service_name
}

output "ai_service_name" {
  description = "AI Engine ECS service name"
  value       = module.compute.ai_service_name
}
output "ai_engine_task_definition_arn" {
  description = "AI Engine ECS task definition ARN"
  value       = module.compute.ai_engine_task_definition_arn
}

output "ai_engine_task_role_arn" {
  description = "AI Engine ECS task role ARN"
  value       = module.compute.ai_engine_task_role_arn
}

output "ai_engine_service_name" {
  description = "AI Engine ECS service name"
  value       = module.compute.ai_engine_service_name
}
output "ai_engine_log_group_name" {
  description = "CloudWatch log group for AI Engine"
  value       = module.compute.ai_engine_log_group_name
}

output "telemetry_api_alb_p99_step_policy_arn" {
  description = "Telemetry API ALB p99 step scaling policy ARN (for observability alarm)"
  value       = module.compute.telemetry_api_alb_p99_step_policy_arn
}

output "ai_engine_latency_step_policy_arn" {
  description = "AI Engine latency step scaling policy ARN (for observability alarm)"
  value       = module.compute.ai_engine_latency_step_policy_arn
}

output "prediction_queue_name" {
  description = "SQS prediction queue name"
  value       = module.data.prediction_queue_name
}

output "prediction_queue_dlq_name" {
  description = "SQS prediction DLQ name"
  value       = module.data.prediction_queue_dlq_name
}

output "operational_alerts_topic_arn" {
  description = "SNS topic ARN for operational CloudWatch alarms"
  value       = module.observability.operational_alerts_topic_arn
}

output "ai_engine_autoscaling_target_resource_id" {
  description = "Application Auto Scaling target resource ID for AI Engine"
  value       = module.compute.ai_engine_autoscaling_target_resource_id
}
