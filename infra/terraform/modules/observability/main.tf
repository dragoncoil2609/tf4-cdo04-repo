# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Operational Alerting, Scaling & Auditing
# -----------------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Build alarm action lists, conditionally including scaling policy ARNs.
  scoped_alarm_actions = compact([
    aws_sns_topic.operational_alerts.arn,
  ])

  telemetry_api_p99_actions = compact([
    aws_sns_topic.operational_alerts.arn,
    var.telemetry_api_alb_p99_scale_out_policy_arn,
  ])

  prediction_scale_out_actions = compact([
    aws_sns_topic.operational_alerts.arn,
    var.prediction_worker_scale_out_policy_arn,
  ])

  prediction_scale_in_actions = compact([
    var.prediction_worker_scale_in_policy_arn,
  ])

  ai_latency_scale_out_actions = compact([
    aws_sns_topic.operational_alerts.arn,
    var.ai_engine_latency_scale_out_policy_arn,
  ])

  # Shared ECS dimensions used across alarms
  telemetry_api_ecs_dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.telemetry_api_service_name
  }

  ai_engine_ecs_dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ai_engine_service_name
  }

  ai_sc_dimensions = {
    ClusterName         = var.ecs_cluster_name
    ServiceName         = var.ai_engine_service_name
    TargetDiscoveryName = "ai-engine"
  }

  # Danh sách target groups cho ALB widgets (full ARN suffix from compute outputs)
  alb_target_groups = [
    var.telemetry_api_target_group_arn_suffix,
    var.ai_engine_target_group_arn_suffix,
  ]

  # ALB metrics cho từng target group — full ARN suffix (no extra targetgroup/ prefix)
  alb_request_metrics = [
    for idx, tg in local.alb_target_groups : (
      idx == 0
      ? ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", tg, {}]
      : [".", ".", ".", var.alb_arn_suffix, ".", tg, { yAxis = "right" }]
    )
  ]

  alb_5xx_metrics = [
    for idx, tg in local.alb_target_groups : (
      idx == 0
      ? ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", tg, {}]
      : [".", ".", ".", var.alb_arn_suffix, ".", tg, { yAxis = "right" }]
    )
  ]

  alb_latency_metrics = [
    for idx, tg in local.alb_target_groups : (
      idx == 0
      ? ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", tg, { stat = "p99" }]
      : [".", ".", ".", var.alb_arn_suffix, ".", tg, { stat = "p99", yAxis = "right" }]
    )
  ]

  # ECS metrics (CPU + Memory) cho từng service - sử dụng variables từ compute module
  ecs_metrics = [
    ["AWS/ECS", "CPUUtilization", "ServiceName", var.telemetry_api_service_name, "ClusterName", var.ecs_cluster_name],
    [".", "MemoryUtilization", ".", var.telemetry_api_service_name, ".", var.ecs_cluster_name, { yAxis = "right" }],
    ["AWS/ECS", "CPUUtilization", "ServiceName", var.worker_service_name, "ClusterName", var.ecs_cluster_name],
    [".", "MemoryUtilization", ".", var.worker_service_name, ".", var.ecs_cluster_name, { yAxis = "right" }],
    ["AWS/ECS", "CPUUtilization", "ServiceName", var.ai_engine_service_name, "ClusterName", var.ecs_cluster_name],
    [".", "MemoryUtilization", ".", var.ai_engine_service_name, ".", var.ecs_cluster_name, { yAxis = "right" }]
  ]
}

# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Operational SNS Alert Channel (CPOA-88/91)
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "operational_alerts" {
  name = "${var.project_name}-operational-alerts-${var.environment}"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_sns_topic_subscription" "operational_email" {
  topic_arn = aws_sns_topic.operational_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- CloudWatch Dashboard (CPOA-89)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "telemetry_system" {
  dashboard_name = "${local.name_prefix}-Telemetry-System"

  dashboard_body = jsonencode({
    widgets = [
      # ── Widget 1: ALB Total Requests ──────────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "1 - ALB - Total Requests"
          period  = 300
          stat    = "Sum"
          region  = var.aws_region
          metrics = local.alb_request_metrics
        }
      },

      # ── Widget 2: ALB 5xx Errors ──────────────────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "2 - ALB - 5xx Errors"
          period  = 300
          stat    = "Sum"
          region  = var.aws_region
          metrics = local.alb_5xx_metrics
        }
      },

      # ── Widget 3: ALB p99 Latency ─────────────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "3 - ALB - p99 Latency"
          period  = 300
          region  = var.aws_region
          metrics = local.alb_latency_metrics
        }
      },

      # ── Widget 4: ECS CPU & Memory ────────────────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "4 - ECS - CPU & Memory Utilization"
          period  = 300
          stat    = "Average"
          region  = var.aws_region
          metrics = local.ecs_metrics
        }
      },

      # ── Widget 5: SQS Messages & Age (Đã đồng bộ biến nhóm) ────────────────
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "5 - SQS - Messages & Age"
          period = 300
          stat   = "Maximum"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.prediction_queue_name],
            [".", "ApproximateAgeOfOldestMessage", ".", var.prediction_queue_name, { yAxis = "right" }],
          ]
        }
      },

      # ── Widget 6: SQS DLQ Depth (Đã đồng bộ biến nhóm) ────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "6 - SQS - DLQ Depth"
          period = 300
          stat   = "Sum"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.prediction_queue_dlq_name],
          ]
        }
      },

      # ── Widget 7: AI Engine Latency ───────────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "7 - AI Engine Latency"
          period = 300
          region = var.aws_region
          metrics = [
            ["Custom/AIEngine", "PredictionLatency", "Service", "AI Engine", { stat = "p95", label = "p95 Latency" }],
            [".", ".", ".", ".", { stat = "p99", label = "p99 Latency", yAxis = "right" }],
          ]
        }
      },

      # ── Widget 8: AI Failures & Fallbacks ────────────────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title  = "8 - AI Failures & Fallbacks"
          period = 300
          region = var.aws_region
          metrics = [
            ["Custom/AIEngine", "FailureCount", "Service", "AI Engine", "ErrorType", "5xx", { stat = "Sum", label = "AI 5xx Errors" }],
            [".", ".", ".", ".", ".", "Timeout", { stat = "Sum", label = "AI Timeouts", yAxis = "right" }],
            [".", "FallbackRate", ".", ".", { stat = "Average", label = "Fallback Rate (%)", yAxis = "right" }],
            [".", "AuditFailures", ".", ".", { stat = "Sum", label = "Audit Write Failures" }],
            [".", "AMPFailures", ".", ".", { stat = "Sum", label = "AMP Ingestion Failures" }],
          ]
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Metric Alarms (CPOA-90)
# Các cảnh báo tĩnh được nối chung vào kênh nhận cảnh báo `operational_alerts` của Vinh
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ai_5xx_alarm" {
  alarm_name          = "${local.name_prefix}-AI-5xx-High"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "FailureCount"
  namespace           = "Custom/AIEngine"
  period              = 60
  statistic           = "Sum"
  threshold           = 10

  alarm_actions      = [aws_sns_topic.operational_alerts.arn]
  ok_actions         = [aws_sns_topic.operational_alerts.arn]
  treat_missing_data = "notBreaching"

  dimensions = {
    Service   = "AI Engine"
    ErrorType = "5xx"
  }

  alarm_description = jsonencode({
    service        = "AI Engine"
    severity       = "high"
    runbook_url    = var.runbook_url
    recommendation = "Check upstream dependencies, analyze prediction queue backlogs, and review system error logs."
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth_alarm" {
  alarm_name          = "${local.name_prefix}-DLQ-Depth-High"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0

  alarm_actions      = [aws_sns_topic.operational_alerts.arn]
  ok_actions         = [aws_sns_topic.operational_alerts.arn]
  treat_missing_data = "notBreaching"

  dimensions = {
    QueueName = var.prediction_queue_dlq_name
  }

  alarm_description = jsonencode({
    service        = "SQS DLQ"
    severity       = "high"
    runbook_url    = var.runbook_url
    recommendation = "Inspect DLQ messages, identify root cause, and replay or discard accordingly."
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_alarm" {
  alarm_name          = "${local.name_prefix}-ALB-5xx-High"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 20

  alarm_actions      = [aws_sns_topic.operational_alerts.arn]
  ok_actions         = [aws_sns_topic.operational_alerts.arn]
  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_description = jsonencode({
    service        = "ALB"
    severity       = "high"
    runbook_url    = var.runbook_url
    recommendation = "Check ECS service health, review target group health checks, and inspect recent deployments."
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# -----------------------------------------------------------------------------
# TASK: CPOA-103 | CDO-W12-058 - Retention policies
# OWNER: Tạ Hoàng Huy
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ai_engine_audit" {
  name              = "/ecs/${var.project_name}-${var.environment}-ai-engine-audit"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-audit-logs"
    Purpose = "ai-engine-audit-logs"
  })
}