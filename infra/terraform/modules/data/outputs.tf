# -----------------------------------------------------------------------------
# Data module -- Outputs
#
# Every output name listed here matches the name that the root module
# (main.tf) and downstream modules (compute, observability) reference.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# AMP (Amazon Managed Service for Prometheus)
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
  description = "AMP remote write endpoint URL (for ADOT collector / Prometheus remote write)"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_endpoint" {
  description = "AMP query endpoint URL (for Prediction Worker PromQL queries)"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/query"
}

# -----------------------------------------------------------------------------
# DynamoDB -- Audit table
# -----------------------------------------------------------------------------
output "audit_table_name" {
  description = "DynamoDB audit table name"
  value       = aws_dynamodb_table.audit.name
}

output "audit_table_arn" {
  description = "DynamoDB audit table ARN"
  value       = aws_dynamodb_table.audit.arn
}

# -----------------------------------------------------------------------------
# DynamoDB -- Policy table
# -----------------------------------------------------------------------------
output "policy_table_name" {
  description = "DynamoDB policy table name"
  value       = aws_dynamodb_table.policy.name
}

# -----------------------------------------------------------------------------
# SQS -- Prediction queue
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# SQS -- Scheduler target DLQ
#
# The EventBridge Scheduler lives in the compute module.
# Exposing the ARN here lets compute wire the scheduler's dead-letter config
# without creating duplicate DLQ resources.
# -----------------------------------------------------------------------------
output "scheduler_dlq_arn" {
  description = "SQS scheduler target DLQ ARN (for EventBridge Scheduler dead-letter config in compute module)"
  value       = aws_sqs_queue.scheduler_dlq.arn
}

output "scheduler_dlq_url" {
  description = "SQS scheduler target DLQ URL"
  value       = aws_sqs_queue.scheduler_dlq.url
}

# -----------------------------------------------------------------------------
# S3 -- Evidence bucket
# -----------------------------------------------------------------------------
output "evidence_bucket_name" {
  description = "S3 evidence bucket name"
  value       = aws_s3_bucket.evidence.bucket
}

output "evidence_bucket_arn" {
  description = "S3 evidence bucket ARN"
  value       = aws_s3_bucket.evidence.arn
}

output "evidence_kms_key_arn" {
  description = "KMS key ARN used for evidence bucket SSE-KMS"
  value       = aws_kms_key.evidence.arn
}

# -----------------------------------------------------------------------------
# S3 -- Baseline bucket (aliases evidence bucket)
#
# The root module references baseline_bucket_name when calling the compute
# module, but the specification allows it to point at the same bucket as
# evidence. This alias avoids unnecessary storage duplication.
# -----------------------------------------------------------------------------
output "baseline_bucket_name" {
  description = "S3 baseline bucket name (aliases evidence bucket)"
  value       = aws_s3_bucket.evidence.bucket
}

# -----------------------------------------------------------------------------
# SNS
# -----------------------------------------------------------------------------
output "sns_alert_topic_arn" {
  description = "SNS alert topic ARN"
  value       = aws_sns_topic.alerts.arn
}

# -----------------------------------------------------------------------------
# Secrets Manager
# -----------------------------------------------------------------------------
output "service_policy_secret_arn" {
  description = "Secrets Manager ARN for service policy configuration"
  value       = aws_secretsmanager_secret.service_policy.arn
}

output "ai_service_config_secret_arn" {
  description = "Secrets Manager ARN for AI service configuration"
  value       = aws_secretsmanager_secret.ai_service_config.arn
}
