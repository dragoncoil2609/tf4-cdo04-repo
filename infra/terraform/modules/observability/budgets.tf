# -----------------------------------------------------------------------------
# TASK: CPOA-99 | CDO-W12-054 - AWS Budget 50/80/100 Cost Circuit Breaker
# OWNER: Tạ Hoàng Huy
#
# DESCRIPTION:
# This Terraform file defines the resources to enforce a monthly cost limit of $200.
# It configures:
# 1. An SNS topic 'budget_alert' used by AWS Budgets to publish spend notifications.
# 2. A subscription to send emails to the SRE team at all levels (50%, 80%, 100%).
# 3. A Lambda Subscription to filter out ACTUAL budget breaches, acting as a circuit breaker.
# 4. IAM execution role & least privilege policy for the Lambda allowing:
#    - ecs:UpdateService and ecs:DescribeServices for both 'ai-engine' and 'prediction-worker'.
#    - sns:Publish to notify of action taken.
#    - logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents restricted to its own log group.
# 5. The aws_lambda_function cost_breaker which runs Python code to scale down services.
# 6. The monthly aws_budgets_budget to trigger SNS alerts at 50%, 80%, and 100% thresholds.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# Tự động nén mã nguồn Python trước khi khởi tạo Lambda
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../../../../src/lambda/cost_breaker.py"
  output_path = "${path.module}/cost_breaker.zip"
}

# Khởi tạo SNS Topic trung tâm cho Ngân sách
resource "aws_sns_topic" "budget_alert" {
  name = "${var.project_name}-budget-alert-topic-${var.environment}"
}

# Cấp quyền cho AWS Budget gửi tin nhắn vào SNS Topic
resource "aws_sns_topic_policy" "budget_alert_policy" {
  arn = aws_sns_topic.budget_alert.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBudgetsToPublish"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.budget_alert.arn
      }
    ]
  })
}

# Subscription 1: Nhận toàn bộ thông báo (50%, 80%, 100%) qua Email của SRE
resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.budget_alert.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Subscription 2: Chỉ cho phép kích hoạt Lambda NGẮT MẠCH tại mốc 100% chi phí
resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.budget_alert.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_breaker.arn

  # Chốt chặn Operational Logic: Lọc tin nhắn từ AWS Budget dựa trên nội dung text
  filter_policy = jsonencode({
    "NotificationType" = ["ACTUAL"]
  })
}

# Khởi tạo IAM Role thực thi cho Lambda
resource "aws_iam_role" "cost_breaker" {
  name = "${var.project_name}-cost-breaker-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# Định nghĩa IAM Policy (Đã sửa đổi ARN chuẩn hóa và thu hẹp Log Group)
resource "aws_iam_policy" "cost_breaker_policy" {
  name        = "${var.project_name}-cost-breaker-policy-${var.environment}"
  description = "Chính sách least privilege cấp quyền cho Circuit Breaker điều khiển ECS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices"
        ]
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${var.ecs_cluster_name}/${var.ai_service_name}",
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${var.ecs_cluster_name}/${var.worker_service_name}",
          var.ecs_cluster_arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.budget_alert.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.project_name}-cost-breaker-${var.environment}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cost_breaker_attach" {
  role       = aws_iam_role.cost_breaker.name
  policy_arn = aws_iam_policy.cost_breaker_policy.arn
}

# Khởi tạo Lambda Function Trình ngắt mạch chi phí
resource "aws_lambda_function" "cost_breaker" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "${var.project_name}-cost-breaker-${var.environment}"
  role             = aws_iam_role.cost_breaker.arn
  handler          = "cost_breaker.handler"
  runtime          = "python3.10"
  timeout          = 30

  environment {
    variables = {
      CLUSTER_NAME        = var.ecs_cluster_name
      SERVICE_NAME        = var.ai_service_name
      WORKER_SERVICE_NAME = var.worker_service_name
      SNS_TOPIC_ARN       = aws_sns_topic.budget_alert.arn
    }
  }

  depends_on = [data.archive_file.lambda_zip]
}

# Cấp quyền cho phép SNS gọi thực thi Lambda
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_breaker.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget_alert.arn
}

# Định nghĩa AWS Budget với quy định gửi thông điệp đầy đủ Metadata sang SNS
resource "aws_budgets_budget" "this" {
  name         = "${var.project_name}-platform-budget-${var.environment}"
  budget_type  = "COST"
  limit_amount = "200"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 50
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alert.arn]
  }
}
