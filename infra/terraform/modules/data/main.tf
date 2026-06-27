# -----------------------------------------------------------------------------
# Data module -- Main resources
#
# Creates:
#   - AMP workspace
#   - DynamoDB audit table (tenant_id / service_time, GSI, TTL, PITR)
#   - DynamoDB policy table (minimal)
#   - SQS prediction queue + DLQ (redrive policy)
#   - SQS scheduler target DLQ (for compute module EventBridge Scheduler)
#   - S3 evidence bucket (KMS encrypted, versioned, lifecycle)
#   - SNS alert topic + optional email subscription
#   - Secrets Manager placeholders (service policy, AI config)
#   - KMS key for evidence bucket SSE-KMS
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Current AWS account identity (used by KMS key policy)
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# KMS key for S3 evidence bucket SSE-KMS
# -----------------------------------------------------------------------------
resource "aws_kms_key" "evidence" {
  description             = "KMS key for ${var.project_name} evidence bucket SSE-KMS"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.evidence_kms.json
}

resource "aws_kms_alias" "evidence" {
  name          = "alias/${var.project_name}-evidence-${var.environment}"
  target_key_id = aws_kms_key.evidence.key_id
}

data "aws_iam_policy_document" "evidence_kms" {
  # Prevent the key from becoming unmanageable
  statement {
    sid     = "EnableIAMUserPermissions"
    effect  = "Allow"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    resources = ["*"]
  }
}

# -----------------------------------------------------------------------------
# Amazon Managed Service for Prometheus (AMP) workspace
# -----------------------------------------------------------------------------
resource "aws_prometheus_workspace" "this" {
  alias = "${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# DynamoDB -- Audit table
#
# Accepted tenant/service/time model:
#   - Partition key: tenant_id  (String)
#   - Sort key:      service_time (String) -- encodes service + time
#   - GSI:           prediction-index on prediction_status + prediction_timestamp
#   - TTL:           expires_at_epoch (Number, Unix epoch seconds)
#   - Billing:       PAY_PER_REQUEST
#   - PITR:          enabled
#   - Encryption:    default AWS-owned key (server_side_encryption enabled)
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "audit" {
  name         = "${var.project_name}-audit-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"
  range_key    = "service_time"

  # Base-table key schema
  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "service_time"
    type = "S"
  }

  # GSI key attributes
  attribute {
    name = "prediction_status"
    type = "S"
  }

  attribute {
    name = "prediction_timestamp"
    type = "S"
  }

  global_secondary_index {
    name            = "prediction-index"
    hash_key        = "prediction_status"
    range_key       = "prediction_timestamp"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expires_at_epoch"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# -----------------------------------------------------------------------------
# DynamoDB -- Policy table (minimal)
#
# Stores service policy configurations.
# root module references policy_table_name in the compute call,
# so we provide a minimal table.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "policy" {
  name         = "${var.project_name}-policy-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "policy_id"

  attribute {
    name = "policy_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

# -----------------------------------------------------------------------------
# SQS -- Prediction queue DLQ (dead-letter queue)
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "prediction_dlq" {
  name                      = "${var.project_name}-prediction-dlq-${var.environment}"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600 # 14 days -- max for DLQ best practice
}

# -----------------------------------------------------------------------------
# SQS -- Prediction queue (source queue)
#
# Routes messages that fail processing (maxReceiveCount exceeded)
# to the DLQ above.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "prediction" {
  name                    = "${var.project_name}-prediction-${var.environment}"
  sqs_managed_sse_enabled = true

  visibility_timeout_seconds = 300    # 5 min; tune to max worker processing time
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.prediction_dlq.arn
    maxReceiveCount     = 3
  })
}

# -----------------------------------------------------------------------------
# SQS -- Scheduler target DLQ
#
# EventBridge Scheduler lives in the compute module.
# This queue serves as the dead-letter target for schedules that exhaust
# their retries. Expose the ARN so the compute module can wire the
# scheduler without creating duplicate DLQ resources.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.project_name}-scheduler-dlq-${var.environment}"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600 # 14 days
}

# -----------------------------------------------------------------------------
# S3 -- Evidence / baseline bucket
#
# Private, KMS-encrypted, versioned, lifecycle-managed.
# baseline_bucket_name output aliases this same bucket.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "evidence" {
  bucket        = "${var.project_name}-evidence-${var.environment}"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.evidence.arn
    }
    bucket_key_enabled = true # reduces KMS costs
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# SNS -- Alert topic + optional email subscription
#
# Email subscription is NOT auto-confirmed by AWS.
# The recipient MUST click the confirmation link in the subscription email.
# This resource is only created when alert_email is non-empty.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${var.project_name}-alerts-${var.environment}"
  kms_master_key_id = "alias/aws/sns" # SNS-managed key; no added cost
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# Secrets Manager -- Service policy config (placeholder, no real secrets)
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "service_policy" {
  name                    = "${var.project_name}-service-policy-${var.environment}"
  description             = "Service policy configuration for ${var.project_name} (${var.environment})"
  recovery_window_in_days = 0 # immediate delete; increase for prod
}

resource "aws_secretsmanager_secret_version" "service_policy" {
  secret_id = aws_secretsmanager_secret.service_policy.id
  secret_string = jsonencode({
    _placeholder = true
    _note        = "Replace with real service policy configuration before production use."
    version      = "0.0.0"
    policies     = {}
  })
}

# -----------------------------------------------------------------------------
# Secrets Manager -- AI service config (placeholder, no real secrets)
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "ai_service_config" {
  name                    = "${var.project_name}-ai-service-config-${var.environment}"
  description             = "AI service configuration for ${var.project_name} (${var.environment}) -- no real secrets in this placeholder"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ai_service_config" {
  secret_id = aws_secretsmanager_secret.ai_service_config.id
  secret_string = jsonencode({
    _placeholder = true
    _note        = "Replace with real AI service configuration before production use."
    model_id     = "PLACEHOLDER"
    region       = var.aws_region
    endpoint     = "https://PLACEHOLDER.amazonaws.com"
    max_tokens   = 4096
    temperature  = 0.7
  })
}
