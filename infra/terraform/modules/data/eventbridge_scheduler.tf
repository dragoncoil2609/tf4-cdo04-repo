# -----------------------------------------------------------------------------
# EventBridge Scheduler -- CDO-W12-008
#
# Scope:
# - Create EventBridge Scheduler jobs that send prediction jobs to SQS every 5 minutes.
# - Scheduler IAM role has sqs:SendMessage to prediction queue and scheduler DLQ.
# - One schedule per demo service: payment-gw, ledger, fraud-detector.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eventbridge_scheduler_role" {
  name        = "${var.project_name}-${var.environment}-eventbridge-scheduler-role"
  description = "EventBridge Scheduler role for sending prediction jobs to SQS"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeSchedulerAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-eventbridge-scheduler-role"
    Purpose = "prediction-scheduler"
  })
}

resource "aws_iam_policy" "eventbridge_scheduler_send_sqs" {
  name        = "${var.project_name}-${var.environment}-scheduler-send-sqs-policy"
  description = "Allow EventBridge Scheduler to send prediction jobs to SQS only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSendMessageToPredictionQueueOnly"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = [
          aws_sqs_queue.prediction.arn,
          aws_sqs_queue.scheduler_dlq.arn,
        ]
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-scheduler-send-sqs-policy"
    Purpose = "prediction-scheduler"
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_scheduler_send_sqs" {
  role       = aws_iam_role.eventbridge_scheduler_role.name
  policy_arn = aws_iam_policy.eventbridge_scheduler_send_sqs.arn
}

resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.project_name}-scheduler-dlq-${var.environment}"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-scheduler-dlq"
    Purpose = "prediction-scheduler-dlq"
  })
}

resource "aws_scheduler_schedule_group" "prediction" {
  name = "${var.project_name}-${var.environment}-prediction-schedules"

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-prediction-schedules"
    Purpose = "prediction-scheduler"
  })
}

resource "aws_scheduler_schedule" "prediction_jobs" {
  for_each = toset(var.prediction_services)

  name        = "${var.project_name}-${var.environment}-${each.value}-prediction-job"
  group_name  = aws_scheduler_schedule_group.prediction.name
  description = "Send prediction job for ${each.value} every 5 minutes"

  schedule_expression          = var.prediction_schedule_expression
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sqs_queue.prediction.arn
    role_arn = aws_iam_role.eventbridge_scheduler_role.arn

    dead_letter_config {
      arn = aws_sqs_queue.scheduler_dlq.arn
    }

    input = jsonencode({
      tenant_id               = var.prediction_tenant_id
      service_id              = each.value
      lookback_window_minutes = var.lookback_window_minutes
      prediction_mode         = var.prediction_mode

      # EventBridge Scheduler input is static.
      # Worker can replace/extend this with a generated correlation_id if required.
      correlation_id = "eventbridge-${each.value}-${var.environment}"
    })
  }

  depends_on = [
    aws_iam_role_policy_attachment.eventbridge_scheduler_send_sqs
  ]
}