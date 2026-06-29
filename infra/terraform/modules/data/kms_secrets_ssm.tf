# -----------------------------------------------------------------------------
# KMS + Secrets/SSM Config -- CDO-W12-007
#
# Scope:
# - Project KMS key for encryption.
# - SSM Parameters for non-sensitive runtime config.
# - Secrets Manager secret containers for sensitive values.
#
# Important:
# - Do NOT store real secret values in Terraform.
# - Secret values should be inserted manually through AWS Console/CLI after apply.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms_policy" {
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    actions = [
      "kms:*"
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.us-east-1.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "project" {
  description             = "KMS key for ${var.project_name}-${var.environment} CDO platform encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_policy.json

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-kms"
    Purpose = "project-encryption"
  })
}

resource "aws_kms_alias" "project" {
  name          = "alias/${var.project_name}-${var.environment}"
  target_key_id = aws_kms_key.project.key_id
}

# -----------------------------------------------------------------------------
# SSM Parameters -- non-sensitive config only
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "aws_region" {
  name        = "/${var.project_name}/${var.environment}/aws_region"
  description = "AWS region for the CDO platform"
  type        = "String"
  value       = var.aws_region

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-aws-region"
    Purpose = "runtime-config"
  })
}

resource "aws_ssm_parameter" "ai_service_name" {
  name        = "/${var.project_name}/${var.environment}/ai/service_name"
  description = "ECS Service Connect name for AI Engine"
  type        = "String"
  value       = var.ai_service_name

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-service-name"
    Purpose = "ai-runtime-config"
  })
}

resource "aws_ssm_parameter" "ai_predict_path" {
  name        = "/${var.project_name}/${var.environment}/ai/predict_path"
  description = "AI prediction endpoint path"
  type        = "String"
  value       = var.ai_predict_path

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-predict-path"
    Purpose = "ai-runtime-config"
  })
}

resource "aws_ssm_parameter" "lookback_window_minutes" {
  name        = "/${var.project_name}/${var.environment}/prediction/lookback_window_minutes"
  description = "Default lookback window for Prediction Worker PromQL query"
  type        = "String"
  value       = tostring(var.lookback_window_minutes)

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-lookback-window"
    Purpose = "prediction-runtime-config"
  })
}

resource "aws_ssm_parameter" "baseline_s3_prefix" {
  name        = "/${var.project_name}/${var.environment}/ai/baseline_s3_prefix"
  description = "S3 prefix for AI Engine baseline files"
  type        = "String"
  value       = var.baseline_s3_prefix

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-baseline-prefix"
    Purpose = "ai-baseline-config"
  })
}

# -----------------------------------------------------------------------------
# Secrets Manager -- secret containers only
# Real values must be added manually after apply.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "tenant_ingest_token" {
  name        = "${var.project_name}/${var.environment}/tenant-ingest-token"
  description = "Tenant ingest token for demo/API auth. Value is managed outside Terraform."
  kms_key_id  = aws_kms_key.project.arn

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-tenant-ingest-token"
    Purpose = "ingest-auth-secret"
  })
}

resource "aws_secretsmanager_secret" "slack_webhook_url" {
  name        = "${var.project_name}/${var.environment}/slack-webhook-url"
  description = "Slack webhook URL for alert integration. Value is managed outside Terraform."
  kms_key_id  = aws_kms_key.project.arn

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-slack-webhook-url"
    Purpose = "alerting-secret"
  })
}

resource "aws_secretsmanager_secret" "ai_sigv4_config" {
  name        = "${var.project_name}/${var.environment}/ai-sigv4-config"
  description = "Optional AI SigV4/auth config. Value is managed outside Terraform."
  kms_key_id  = aws_kms_key.project.arn

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-sigv4-config"
    Purpose = "ai-auth-secret"
  })
}