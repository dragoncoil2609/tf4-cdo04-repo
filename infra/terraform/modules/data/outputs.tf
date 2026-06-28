# -----------------------------------------------------------------------------
# Data module -- Outputs
# -----------------------------------------------------------------------------

output "amp_workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "AMP workspace ARN"
  value       = aws_prometheus_workspace.this.arn
}

output "amp_remote_write_endpoint" {
  description = "AMP remote write endpoint URL"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_endpoint" {
  description = "AMP query endpoint URL"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/query"
}

output "audit_table_name" {
  description = "DynamoDB audit table name"
  value       = aws_dynamodb_table.audit.name
}

output "audit_table_arn" {
  description = "DynamoDB audit table ARN"
  value       = aws_dynamodb_table.audit.arn
}

output "prediction_queue_url" {
  description = "SQS prediction queue URL"
  value       = aws_sqs_queue.prediction.url
}

output "prediction_queue_arn" {
  description = "SQS prediction queue ARN"
  value       = aws_sqs_queue.prediction.arn
}

output "prediction_queue_dlq_url" {
  description = "SQS prediction DLQ URL"
  value       = aws_sqs_queue.prediction_dlq.url
}

output "prediction_queue_dlq_arn" {
  description = "SQS prediction DLQ ARN"
  value       = aws_sqs_queue.prediction_dlq.arn
}

output "evidence_bucket_name" {
  description = "S3 evidence bucket name"
  value       = aws_s3_bucket.evidence.bucket
}

output "evidence_bucket_arn" {
  description = "S3 evidence bucket ARN"
  value       = aws_s3_bucket.evidence.arn
}
output "kms_key_arn" {
  description = "Project KMS key ARN"
  value       = aws_kms_key.project.arn
}

output "kms_key_alias" {
  description = "Project KMS key alias"
  value       = aws_kms_alias.project.name
}

output "ssm_aws_region_parameter" {
  description = "SSM parameter name for AWS region"
  value       = aws_ssm_parameter.aws_region.name
}

output "ssm_ai_service_name_parameter" {
  description = "SSM parameter name for AI service name"
  value       = aws_ssm_parameter.ai_service_name.name
}

output "ssm_ai_predict_path_parameter" {
  description = "SSM parameter name for AI predict path"
  value       = aws_ssm_parameter.ai_predict_path.name
}

output "ssm_lookback_window_parameter" {
  description = "SSM parameter name for lookback window"
  value       = aws_ssm_parameter.lookback_window_minutes.name
}

output "ssm_baseline_s3_prefix_parameter" {
  description = "SSM parameter name for baseline S3 prefix"
  value       = aws_ssm_parameter.baseline_s3_prefix.name
}

output "tenant_ingest_token_secret_arn" {
  description = "Secrets Manager ARN for tenant ingest token"
  value       = aws_secretsmanager_secret.tenant_ingest_token.arn
}

output "slack_webhook_secret_arn" {
  description = "Secrets Manager ARN for Slack webhook"
  value       = aws_secretsmanager_secret.slack_webhook_url.arn
}

output "ai_sigv4_config_secret_arn" {
  description = "Secrets Manager ARN for AI SigV4 config"
  value       = aws_secretsmanager_secret.ai_sigv4_config.arn
}