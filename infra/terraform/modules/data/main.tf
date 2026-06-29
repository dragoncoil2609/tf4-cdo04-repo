# -----------------------------------------------------------------------------
# Data module -- Main resources
#
# Vinh-owned scope (CPOA-42): AMP workspace, SQS/DLQ, DynamoDB audit table,
# and S3 evidence bucket foundation.
# -----------------------------------------------------------------------------

resource "aws_prometheus_workspace" "this" {
  alias = "${var.project_name}-${var.environment}"
}

resource "aws_dynamodb_table" "audit" {
  name         = "${var.project_name}-audit-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tenant_id"
  range_key    = "service_time"

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "service_time"
    type = "S"
  }

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
# TODO (CPOA-72): DynamoDB service policy fallback rules -- owned by Phan Minh Tuấn.
# Placeholder only: add service policy table/items when fallback engine work lands.
# -----------------------------------------------------------------------------

resource "aws_sqs_queue" "prediction_dlq" {
  name                      = "${var.project_name}-prediction-dlq-${var.environment}"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "prediction" {
  name                    = "${var.project_name}-prediction-${var.environment}"
  sqs_managed_sse_enabled = true

  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.prediction_dlq.arn
    maxReceiveCount     = 3
  })
}

# -----------------------------------------------------------------------------
# TODO (CPOA-44): EventBridge Scheduler DLQ -- owned by Truong An.
# Placeholder only: create scheduler target DLQ together with scheduler resource.
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
      sse_algorithm = "AES256"
    }
  }
}

# -----------------------------------------------------------------------------
# TASK: CPOA-103 | CDO-W12-058 - Retention policies
# OWNER: Tạ Hoàng Huy
#
# DESCRIPTION:
# Cấu hình chính sách vòng đời S3 cho evidence bucket:
# 1. Rule 1: Tự động xóa dữ liệu lỗi trong prefix failure-buffer/ sau 7 ngày.
# 2. Rule 2: Xóa toàn bộ dữ liệu evidence và baseline khác sau 90 ngày.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  # Rule 1: Tự động xóa dữ liệu lỗi trong failure-buffer/ sau 7 ngày
  rule {
    id     = "delete-failure-buffer-7-days"
    status = "Enabled"

    filter {
      prefix = "failure-buffer/"
    }

    expiration {
      days = 7
    }
  }

  # Rule 2: Luu giu toan bo du lieu evidence va baseline khac trong 90 ngay
  rule {
    id     = "expire-all-other-data-90-days"
    status = "Enabled"

    filter {
      # Ap dung cho phan con lai, logic duoc phan tach an toan bang ID cua Rule
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
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

resource "aws_s3_bucket_policy" "evidence" {
  bucket = aws_s3_bucket.evidence.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonTLS"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.evidence.arn,
          "${aws_s3_bucket.evidence.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# KMS + Secrets/SSM config is implemented in kms_secrets_ssm.tf.
# Evidence bucket currently uses AES256 encryption; migration to project KMS
# can be handled separately if required by security review.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# TODO (CPOA-69/CPOA-91): SNS alert channels -- owned by Nguyen Huy Hoang /
# Nguyen Quach Khang Ninh. Placeholder only; no alert topic here.
# -----------------------------------------------------------------------------
