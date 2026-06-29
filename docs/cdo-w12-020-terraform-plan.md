# CDO-W12-020 — Terraform IaC Integration Plan

Tài liệu này hướng dẫn chi tiết cách tích hợp các tài nguyên hạ tầng AWS của Task CDO-W12-020 (S3 Failure Buffer, IAM task role policies, Lambda checker, EventBridge Schedule, và CloudWatch Alarm) vào hệ thống Terraform hiện tại của dự án.

---

## 1. Những phần còn thiếu trong Terraform hiện tại

Hiện tại, thư mục `infra/terraform` mới chỉ có các nền tảng cơ bản và thiếu các tài nguyên phục vụ cho S3 Failure Buffer:
1. **S3 failure buffer bucket** và các cấu hình bảo mật liên quan (public access block, lifecycle configuration, server-side encryption).
2. **Quyền truy cập S3 (PutObject)** trong IAM Role của Telemetry API Task.
3. **Các biến môi trường cấu hình Retry và S3 Buffer** trong container definition của ECS Task.
4. **Lambda function, IAM Execution Role, EventBridge Rule** để quét tuổi object cũ nhất và đẩy metric.
5. **CloudWatch Metric Alarm** dựa trên metric của Lambda để cảnh báo khi object cũ nhất vượt quá 300 giây.

---

## 2. Chi tiết các tệp tin cần bổ sung và chỉnh sửa

### 2.1. Module `data` (Quản lý S3 Failure Buffer Bucket)

#### Thêm vào `infra/terraform/modules/data/main.tf`:
```hcl
resource "aws_s3_bucket" "failure_buffer" {
  bucket        = "${var.project_name}-failure-buffer-${var.environment}"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "failure_buffer" {
  bucket = aws_s3_bucket.failure_buffer.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "failure_buffer" {
  bucket = aws_s3_bucket.failure_buffer.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "failure_buffer" {
  bucket = aws_s3_bucket.failure_buffer.id

  rule {
    id     = "expire-old-failures-after-30-days"
    status = "Enabled"

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "failure_buffer" {
  bucket = aws_s3_bucket.failure_buffer.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "failure_buffer" {
  bucket = aws_s3_bucket.failure_buffer.id

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
          aws_s3_bucket.failure_buffer.arn,
          "${aws_s3_bucket.failure_buffer.arn}/*",
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
```

#### Thêm vào `infra/terraform/modules/data/outputs.tf`:
```hcl
output "failure_buffer_bucket_name" {
  description = "S3 failure buffer bucket name"
  value       = aws_s3_bucket.failure_buffer.bucket
}

output "failure_buffer_bucket_arn" {
  description = "S3 failure buffer bucket ARN"
  value       = aws_s3_bucket.failure_buffer.arn
}
```

---

### 2.2. Module `compute` (Cấu hình ECS Task Role & Env Variables)

#### Thêm vào `infra/terraform/modules/compute/variables.tf`:
```hcl
variable "failure_buffer_bucket_name" {
  description = "S3 failure buffer bucket name"
  type        = string
}

variable "failure_buffer_bucket_arn" {
  description = "S3 failure buffer bucket ARN"
  type        = string
}
```

#### Cập nhật `aws_iam_role_policy.telemetry_api_task` trong `infra/terraform/modules/compute/main.tf`:
Bổ sung quyền ghi vào S3 bucket ở phần `Statement`:
```diff
      {
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = var.amp_workspace_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = var.prediction_queue_arn
+     },
+     {
+       Effect   = "Allow"
+       Action   = ["s3:PutObject"]
+       Resource = "${var.failure_buffer_bucket_arn}/telemetry-failures/*"
+     }
```

#### Cập nhật biến môi trường container definition trong `aws_ecs_task_definition.telemetry_api`:
Bổ sung cấu hình cho S3 Buffer và Retry:
```diff
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "AMP_REMOTE_WRITE_ENDPOINT", value = var.amp_remote_write_endpoint },
        { name = "PREDICTION_QUEUE_URL", value = var.prediction_queue_url },
+       { name = "S3_FAILURE_BUFFER_ENABLED", value = "true" },
+       { name = "S3_FAILURE_BUFFER_BUCKET", value = var.failure_buffer_bucket_name },
+       { name = "S3_FAILURE_BUFFER_PREFIX", value = "telemetry-failures/" },
+       { name = "AMP_DELIVERY_ENABLED", value = "true" },
+       { name = "AMP_DELIVERY_MAX_RETRIES", value = "3" },
+       { name = "AMP_DELIVERY_RETRY_BASE_DELAY_MS", value = "500" },
+       { name = "AMP_DELIVERY_RETRY_MAX_DELAY_MS", value = "5000" }
      ]
```

---

### 2.3. Module `observability` (Giám sát & CloudWatch Alarm)

#### Thêm vào `infra/terraform/modules/observability/variables.tf`:
```hcl
variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "failure_buffer_bucket_name" {
  type = string
}

variable "failure_buffer_bucket_arn" {
  type = string
}
```

#### Thêm vào `infra/terraform/modules/observability/main.tf`:
```hcl
# IAM Role cho Lambda Checker
resource "aws_iam_role" "lambda_checker" {
  name = "${var.project_name}-lambda-checker-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })
}

# IAM Policy cho Lambda Checker (List S3 + Put CloudWatch Metric)
resource "aws_iam_role_policy" "lambda_checker_policy" {
  name = "${var.project_name}-lambda-checker-policy-${var.environment}"
  role = aws_iam_role.lambda_checker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.failure_buffer_bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.failure_buffer_bucket_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

# Zip Lambda function code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../../../infra/lambda/failure_buffer_age_checker.py"
  output_path = "${path.module}/files/failure_buffer_age_checker.zip"
}

# Lambda function
resource "aws_lambda_function" "failure_buffer_age_checker" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project_name}-failure-buffer-age-checker-${var.environment}"
  role             = aws_iam_role.lambda_checker.arn
  handler          = "failure_buffer_age_checker.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      S3_FAILURE_BUFFER_BUCKET = var.failure_buffer_bucket_name
      S3_FAILURE_BUFFER_PREFIX = "telemetry-failures/"
      CLOUDWATCH_NAMESPACE     = "CDO/TelemetryApi"
    }
  }
}

# EventBridge Trigger Lambda mỗi 1 phút
resource "aws_cloudwatch_event_rule" "every_minute" {
  name                = "${var.project_name}-failure-buffer-age-rule-${var.environment}"
  description         = "Triggers Lambda check S3 failure buffer age every minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "trigger_lambda" {
  rule      = aws_cloudwatch_event_rule.every_minute.name
  target_id = "TriggerLambda"
  arn       = aws_lambda_function.failure_buffer_age_checker.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failure_buffer_age_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_minute.arn
}

# CloudWatch Alarm (Oldest object age > 300s)
resource "aws_cloudwatch_metric_alarm" "failure_buffer_object_age_alarm" {
  alarm_name          = "${var.project_name}-FailureBufferOldestObjectAgeAlarm-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailureBufferOldestObjectAgeSeconds"
  namespace           = "CDO/TelemetryApi"
  period              = 60
  statistic           = "Maximum"
  threshold           = 300
  alarm_description   = "Triggers if the oldest object in the S3 failure buffer is older than 5 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    BucketName = var.failure_buffer_bucket_name
  }
}
```

---

### 2.4. Root Module (`infra/terraform/main.tf` & `outputs.tf`)

#### Cập nhật liên kết Module trong `infra/terraform/main.tf`:
```diff
module "compute" {
  source = "./modules/compute"

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  amp_remote_write_endpoint = module.data.amp_remote_write_endpoint
  amp_workspace_arn         = module.data.amp_workspace_arn
  prediction_queue_url      = module.data.prediction_queue_url
  prediction_queue_arn      = module.data.prediction_queue_arn
  telemetry_api_image_tag   = var.telemetry_api_image_tag
+ failure_buffer_bucket_name = module.data.failure_buffer_bucket_name
+ failure_buffer_bucket_arn  = module.data.failure_buffer_bucket_arn
}

module "observability" {
  source = "./modules/observability"
- # Placeholder module only; implementation belongs to CPOA-88 assignee.
+ project_name               = var.project_name
+ environment                = var.environment
+ aws_region                 = var.aws_region
+ failure_buffer_bucket_name = module.data.failure_buffer_bucket_name
+ failure_buffer_bucket_arn  = module.data.failure_buffer_bucket_arn
}
```

#### Thêm vào `infra/terraform/outputs.tf`:
```hcl
output "failure_buffer_bucket_name" {
  description = "S3 failure buffer bucket name"
  value       = module.data.failure_buffer_bucket_name
}
```
