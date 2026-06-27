# -----------------------------------------------------------------------------
# CDO-04 Observability Module
#
# Creates:
#   - SNS topic + email subscription for alarm delivery
#   - CloudWatch alarms: ALB 5xx/latency, ECS CPU/Memory, SQS/DLQ depth,
#     DynamoDB throttles & system errors
#   - CloudWatch dashboard with ECS, ALB, SQS, DynamoDB widgets
#   - AWS Budget with email notification
#
# Parses queue names from SQS URLs and ALB/TG suffixes from ARNs for metric
# dimensions. Does NOT rely on the data module's SNS topic (root interface
# passes alert_email only, not an SNS ARN).
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Locals -- ARN / URL parsing for CloudWatch metric dimensions
# -----------------------------------------------------------------------------
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # ALB LoadBalancer dimension = everything after "loadbalancer/" in the ARN
  # e.g. arn:aws:elasticloadbalancing:...:loadbalancer/app/my-alb/abc123
  #   -> app/my-alb/abc123
  alb_dimension = replace(var.alb_arn, "/^.*:loadbalancer\\//", "")

  # TargetGroup dimension = "targetgroup/" + suffix from ARN
  # e.g. arn:aws:elasticloadbalancing:...:targetgroup/my-tg/def456
  #   -> targetgroup/my-tg/def456
  tg_suffix    = replace(var.alb_target_group_arn, "/^.*:targetgroup\\//", "")
  tg_dimension = "targetgroup/${local.tg_suffix}"

  # QueueName = last path segment of the SQS URL
  # e.g. https://sqs.us-east-1.amazonaws.com/123456789/tf4-cdo04-sandbox-prediction
  #   -> tf4-cdo04-sandbox-prediction
  prediction_queue_name     = element(split("/", var.prediction_queue_url), length(split("/", var.prediction_queue_url)) - 1)
  prediction_queue_dlq_name = element(split("/", var.prediction_queue_dlq_url), length(split("/", var.prediction_queue_dlq_url)) - 1)

  # ECS service names list for iterating in dashboard widgets
  ecs_service_names = compact([
    var.telemetry_api_service_name,
    var.prediction_worker_service_name,
    var.ai_engine_service_name,
    var.adot_collector_service_name,
  ])

  # Whether alerting is configured
  alerting_enabled = var.alert_email != ""

  # Budget name
  budget_name = "${local.name_prefix}-monthly-budget"
}

# -----------------------------------------------------------------------------
# SNS topic for alarm actions
#
# This module creates its own SNS topic because the root interface passes
# alert_email rather than an SNS ARN. The data module's SNS topic is separate
# (owned by the data layer for its own alerting needs).
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alarms" {
  name = "${local.name_prefix}-observability-alarms"
  tags = {
    Name        = "${local.name_prefix}-observability-alarms"
    Description = "CloudWatch alarm notifications for the observability module"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count = local.alerting_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# =============================================================================
# CLOUDWATCH ALARMS
# =============================================================================

# -----------------------------------------------------------------------------
# ALB -- Target 5XX errors (sum over 1 evaluation period)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name          = "${local.name_prefix}-alb-target-5xx"
  alarm_description   = "ALB target 5XX errors exceeded threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 5
  period              = 60
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"

  dimensions = {
    LoadBalancer = local.alb_dimension
    TargetGroup  = local.tg_dimension
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-alb-target-5xx"
    Target = "ALB"
    Metric = "HTTPCode_Target_5XX_Count"
  }
}

# -----------------------------------------------------------------------------
# ALB -- Target response time (p95)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_target_latency_p95" {
  alarm_name          = "${local.name_prefix}-alb-target-latency-p95"
  alarm_description   = "ALB target response time p95 exceeded threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 2 # seconds
  period              = 60
  extended_statistic  = "p95"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ApplicationELB"
  metric_name = "TargetResponseTime"

  dimensions = {
    LoadBalancer = local.alb_dimension
    TargetGroup  = local.tg_dimension
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-alb-target-latency-p95"
    Target = "ALB"
    Metric = "TargetResponseTime"
  }
}

# -----------------------------------------------------------------------------
# ALB -- Unhealthy host count
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-unhealthy-hosts"
  alarm_description   = "ALB has unhealthy targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0
  period              = 60
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"

  dimensions = {
    LoadBalancer = local.alb_dimension
    TargetGroup  = local.tg_dimension
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-alb-unhealthy-hosts"
    Target = "ALB"
    Metric = "UnHealthyHostCount"
  }
}

# -----------------------------------------------------------------------------
# ECS -- Service CPU utilization (Telemetry API)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ecs_telemetry_api_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-telemetry-api-cpu"
  alarm_description   = "Telemetry API ECS service CPU utilization > 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  period              = 60
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.telemetry_api_service_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-ecs-telemetry-api-cpu"
    Target = "ECS/TelemetryAPI"
    Metric = "CPUUtilization"
  }
}

# -----------------------------------------------------------------------------
# ECS -- Service CPU utilization (Prediction Worker)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ecs_prediction_worker_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-prediction-worker-cpu"
  alarm_description   = "Prediction Worker ECS service CPU utilization > 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  period              = 60
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.prediction_worker_service_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-ecs-prediction-worker-cpu"
    Target = "ECS/PredictionWorker"
    Metric = "CPUUtilization"
  }
}

# -----------------------------------------------------------------------------
# ECS -- Service CPU utilization (AI Engine)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ecs_ai_engine_cpu" {
  alarm_name          = "${local.name_prefix}-ecs-ai-engine-cpu"
  alarm_description   = "AI Engine ECS service CPU utilization > 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  period              = 60
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ECS"
  metric_name = "CPUUtilization"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ai_engine_service_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-ecs-ai-engine-cpu"
    Target = "ECS/AIEngine"
    Metric = "CPUUtilization"
  }
}

# -----------------------------------------------------------------------------
# ECS -- Service Memory utilization (AI Engine, typically most memory-heavy)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ecs_ai_engine_memory" {
  alarm_name          = "${local.name_prefix}-ecs-ai-engine-memory"
  alarm_description   = "AI Engine ECS service Memory utilization > 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 80
  period              = 60
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/ECS"
  metric_name = "MemoryUtilization"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ai_engine_service_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-ecs-ai-engine-memory"
    Target = "ECS/AIEngine"
    Metric = "MemoryUtilization"
  }
}

# -----------------------------------------------------------------------------
# SQS -- Prediction queue depth (visible messages)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "sqs_prediction_queue_depth" {
  alarm_name          = "${local.name_prefix}-sqs-prediction-queue-depth"
  alarm_description   = "Prediction SQS queue depth (visible messages) exceeded threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 100
  period              = 60
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"

  dimensions = {
    QueueName = local.prediction_queue_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-sqs-prediction-queue-depth"
    Target = "SQS/Prediction"
    Metric = "ApproximateNumberOfMessagesVisible"
  }
}

# -----------------------------------------------------------------------------
# SQS -- Prediction DLQ depth (any messages in DLQ are bad)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "sqs_prediction_dlq_depth" {
  alarm_name          = "${local.name_prefix}-sqs-prediction-dlq-depth"
  alarm_description   = "Prediction DLQ has messages -- indicates processing failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 0
  period              = 60
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"

  dimensions = {
    QueueName = local.prediction_queue_dlq_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-sqs-prediction-dlq-depth"
    Target = "SQS/PredictionDLQ"
    Metric = "ApproximateNumberOfMessagesVisible"
  }
}

# -----------------------------------------------------------------------------
# SQS -- Prediction queue age (oldest message)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "sqs_prediction_queue_age" {
  alarm_name          = "${local.name_prefix}-sqs-prediction-queue-age"
  alarm_description   = "Prediction SQS oldest message age exceeded threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 300 # 5 minutes in seconds
  period              = 60
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/SQS"
  metric_name = "ApproximateAgeOfOldestMessage"

  dimensions = {
    QueueName = local.prediction_queue_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-sqs-prediction-queue-age"
    Target = "SQS/Prediction"
    Metric = "ApproximateAgeOfOldestMessage"
  }
}

# -----------------------------------------------------------------------------
# DynamoDB -- Audit table throttled read requests
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dynamodb_audit_read_throttles" {
  alarm_name          = "${local.name_prefix}-dynamodb-audit-read-throttles"
  alarm_description   = "DynamoDB audit table read throttles detected"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0
  period              = 60
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/DynamoDB"
  metric_name = "ReadThrottleEvents"

  dimensions = {
    TableName = var.audit_table_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-dynamodb-audit-read-throttles"
    Target = "DynamoDB/Audit"
    Metric = "ReadThrottleEvents"
  }
}

# -----------------------------------------------------------------------------
# DynamoDB -- Audit table throttled write requests
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dynamodb_audit_write_throttles" {
  alarm_name          = "${local.name_prefix}-dynamodb-audit-write-throttles"
  alarm_description   = "DynamoDB audit table write throttles detected"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0
  period              = 60
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/DynamoDB"
  metric_name = "WriteThrottleEvents"

  dimensions = {
    TableName = var.audit_table_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-dynamodb-audit-write-throttles"
    Target = "DynamoDB/Audit"
    Metric = "WriteThrottleEvents"
  }
}

# -----------------------------------------------------------------------------
# DynamoDB -- Audit table system errors
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "dynamodb_audit_system_errors" {
  alarm_name          = "${local.name_prefix}-dynamodb-audit-system-errors"
  alarm_description   = "DynamoDB audit table system errors detected"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0
  period              = 60
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  namespace   = "AWS/DynamoDB"
  metric_name = "SystemErrors"

  dimensions = {
    TableName = var.audit_table_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = {
    Name   = "${local.name_prefix}-dynamodb-audit-system-errors"
    Target = "DynamoDB/Audit"
    Metric = "SystemErrors"
  }
}

# =============================================================================
# CLOUDWATCH DASHBOARD
# =============================================================================
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name_prefix
  dashboard_body = jsonencode({
    widgets = concat(
      # --- Header ---
      [{
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# ${local.name_prefix} -- Observability Dashboard"
        }
      }],

      # --- ECS: Service CPU ---
      [for i, svc in local.ecs_service_names : {
        type   = "metric"
        x      = i * 6
        y      = 1
        width  = 6
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "ECS CPU -- ${svc}"
          stat    = "Average"
          period  = 60
          yAxis   = { left = { min = 0, max = 100 } }
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", svc, { stat = "Average" }],
            [".", "MemoryUtilization", ".", ".", ".", ".", { stat = "Average" }],
          ]
          annotations = {
            horizontal = [
              { value = 80, label = "CPU 80%", color = "#ff7f0e" },
            ]
          }
        }
      }],

      # --- ALB: 5XX counts ---
      [{
        type   = "metric"
        x      = 0
        y      = 7
        width  = 8
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "ALB Target 5XX"
          stat    = "Sum"
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_dimension, "TargetGroup", local.tg_dimension, { stat = "Sum", label = "Target 5XX" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb_dimension, { stat = "Sum", label = "ELB 5XX" }],
          ]
        }
      }],

      # --- ALB: Target response time ---
      [{
        type   = "metric"
        x      = 8
        y      = 7
        width  = 8
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "ALB Target Response Time (ms)"
          stat    = "p95"
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_dimension, "TargetGroup", local.tg_dimension, { stat = "p95" }],
            [".", ".", ".", ".", ".", ".", { stat = "Average" }],
          ]
        }
      }],

      # --- ALB: Request count ---
      [{
        type   = "metric"
        x      = 16
        y      = 7
        width  = 8
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "ALB Request Count"
          stat    = "Sum"
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_dimension, { stat = "Sum" }],
          ]
        }
      }],

      # --- SQS: Queue depth ---
      [{
        type   = "metric"
        x      = 0
        y      = 13
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "SQS -- Prediction Queue Depth"
          stat    = "Average"
          period  = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.prediction_queue_name, { stat = "Average" }],
            [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { stat = "Average" }],
          ]
          annotations = {
            horizontal = [
              { value = 100, label = "Alarm threshold", color = "#d62728" },
            ]
          }
        }
      }],

      # --- SQS: DLQ depth ---
      [{
        type   = "metric"
        x      = 12
        y      = 13
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "SQS -- Prediction DLQ Depth"
          stat    = "Sum"
          period  = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.prediction_queue_dlq_name, { stat = "Sum", label = "DLQ Depth" }],
          ]
        }
      }],

      # --- SQS: Queue age (standalone) ---
      [{
        type   = "metric"
        x      = 12
        y      = 19
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "SQS -- Prediction Queue Oldest Message Age"
          stat    = "Maximum"
          period  = 60
          metrics = [
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", local.prediction_queue_name, { stat = "Maximum" }],
          ]
        }
      }],

      # --- DynamoDB: Throttles ---
      [{
        type   = "metric"
        x      = 0
        y      = 19
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "DynamoDB Audit Table -- Throttles"
          stat    = "Sum"
          period  = 60
          metrics = [
            ["AWS/DynamoDB", "ReadThrottleEvents", "TableName", var.audit_table_name, { stat = "Sum", label = "ReadThrottles" }],
            [".", "WriteThrottleEvents", ".", ".", { stat = "Sum", label = "WriteThrottles" }],
          ]
        }
      }],

      # --- DynamoDB: Errors + Latency ---
      [{
        type   = "metric"
        x      = 0
        y      = 25
        width  = 12
        height = 6
        properties = {
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          title   = "DynamoDB Audit Table -- Errors & Latency"
          stat    = "Sum"
          period  = 60
          metrics = [
            ["AWS/DynamoDB", "SystemErrors", "TableName", var.audit_table_name, { stat = "Sum", label = "SystemErrors" }],
            [".", "SuccessfulRequestLatency", ".", ".", { stat = "Average", label = "Latency (ms)" }],
          ]
        }
      }],

      # --- AMP workspace reference ---
      [{
        type   = "text"
        x      = 12
        y      = 25
        width  = 12
        height = 4
        properties = {
          markdown = <<-MARKDOWN
          ## Amazon Managed Prometheus
          - **Workspace ARN**: `${var.amp_workspace_arn}`
          - **Region**: ${var.aws_region}
          - AMP metrics are ingested via the standalone ADOT Collector ECS service exposed through Service Connect.
          - Query AMP directly in the [AMP console](https://console.aws.amazon.com/prometheus/home?region=${var.aws_region}#/workspaces) or via Grafana.
          MARKDOWN
        }
      }],

      # --- Budget gauge placeholder ---
      [{
        type   = "text"
        x      = 12
        y      = 29
        width  = 12
        height = 2
        properties = {
          markdown = <<-MARKDOWN
          ## AWS Budget
          - **Monthly budget**: $${format("%.2f", var.budget_limit)}
          - Budget alerts are sent to: `${var.alert_email != "" ? var.alert_email : "N/A"}`
          - See [AWS Budgets console](https://console.aws.amazon.com/billing/home?region=${var.aws_region}#/budgets) for details.
          MARKDOWN
        }
      }]
    )
  })
}

# =============================================================================
# AWS BUDGETS
#
# Uses aws_budgets_budget with an email subscriber. No SNS plumbing needed --
# Budgets supports direct EMAIL subscription type natively.
# =============================================================================
resource "aws_budgets_budget" "monthly" {
  name              = local.budget_name
  budget_type       = "COST"
  limit_amount      = tostring(var.budget_limit)
  limit_unit        = "USD"
  time_period_start = "2024-01-01_00:00"
  time_unit         = "MONTHLY"

  dynamic "notification" {
    for_each = local.alerting_enabled ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
