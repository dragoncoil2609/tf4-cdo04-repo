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
