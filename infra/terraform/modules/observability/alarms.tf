# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- CloudWatch Alarms (CPOA-88)
# -----------------------------------------------------------------------------

# =============================================================================
# Telemetry API Alarms
# =============================================================================

# ECS CPU > 70%
resource "aws_cloudwatch_metric_alarm" "telemetry_api_cpu" {
  alarm_name          = "${var.project_name}-telemetry-api-cpu-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Telemetry API ECS CPU utilization exceeds 70%"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  dimensions = local.telemetry_api_ecs_dimensions
}

# ECS Memory > 75%
resource "aws_cloudwatch_metric_alarm" "telemetry_api_memory" {
  alarm_name          = "${var.project_name}-telemetry-api-memory-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "Telemetry API ECS memory utilization exceeds 75%"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  dimensions = local.telemetry_api_ecs_dimensions
}

# ALB p99 TargetResponseTime > 0.8s for 5 min (period=60, evaluation_periods=5)
# Conditionally created only when ALB ARN suffix is provided.
resource "aws_cloudwatch_metric_alarm" "telemetry_api_alb_p99" {
  alarm_name          = "${var.project_name}-telemetry-api-alb-p99-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 0.8
  alarm_description   = "ALB p99 TargetResponseTime exceeds 0.8s for Telemetry API"
  alarm_actions       = local.telemetry_api_p99_actions
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.telemetry_api_target_group_arn_suffix
  }
}

# ALB 5xx error rate > 1% for 5 min via metric math
resource "aws_cloudwatch_metric_alarm" "telemetry_api_alb_5xx_rate" {
  alarm_name          = "${var.project_name}-telemetry-api-alb-5xx-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  threshold           = 1
  alarm_description   = "ALB 5xx error rate exceeds 1% for Telemetry API"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    expression  = "(m1 / m2) * 100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "m1"

    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.telemetry_api_target_group_arn_suffix
      }
    }
  }

  metric_query {
    id = "m2"

    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"

      dimensions = {
        LoadBalancer = var.alb_arn_suffix
        TargetGroup  = var.telemetry_api_target_group_arn_suffix
      }
    }
  }
}

# Running task count < 2
resource "aws_cloudwatch_metric_alarm" "telemetry_api_running_tasks" {
  alarm_name          = "${var.project_name}-telemetry-api-running-tasks-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = 2
  alarm_description   = "Telemetry API running task count is below 2"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "breaching"

  dimensions = local.telemetry_api_ecs_dimensions
}

# =============================================================================
# Prediction / SQS Alarms
# =============================================================================

# SQS queue age > 120s -- SNS + worker scale-out
resource "aws_cloudwatch_metric_alarm" "prediction_queue_age" {
  alarm_name          = "${var.project_name}-prediction-queue-age-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 120
  alarm_description   = "SQS prediction queue age exceeds 120 seconds"
  alarm_actions       = local.prediction_scale_out_actions
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.prediction_queue_name
  }
}

# SQS visible messages > 20 for 5 minutes -- SNS + worker scale-out
resource "aws_cloudwatch_metric_alarm" "prediction_queue_visible_high" {
  alarm_name          = "${var.project_name}-prediction-queue-visible-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 20
  alarm_description   = "SQS prediction queue visible messages exceed 20 for 5 minutes"
  alarm_actions       = local.prediction_scale_out_actions
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.prediction_queue_name
  }
}

# SQS visible messages <= 0 for 10 minutes -- worker scale-in only (no SNS)
resource "aws_cloudwatch_metric_alarm" "prediction_queue_idle" {
  alarm_name          = "${var.project_name}-prediction-queue-idle-${var.environment}"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "SQS prediction queue idle for 10 minutes (scale-in signal)"
  alarm_actions       = local.prediction_scale_in_actions
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.prediction_queue_name
  }
}

# DLQ visible > 0 -- SNS
resource "aws_cloudwatch_metric_alarm" "prediction_dlq_visible" {
  alarm_name          = "${var.project_name}-prediction-dlq-visible-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "SQS prediction DLQ has visible messages"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.prediction_queue_dlq_name
  }
}

# Worker running tasks < 1 -- SNS
resource "aws_cloudwatch_metric_alarm" "prediction_worker_running_tasks" {
  alarm_name          = "${var.project_name}-prediction-worker-running-tasks-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Prediction Worker running task count is below 1"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.worker_service_name
  }
}

# =============================================================================
# AI Engine Alarms
# =============================================================================

# AI ECS CPU > 70%
resource "aws_cloudwatch_metric_alarm" "ai_engine_cpu" {
  alarm_name          = "${var.project_name}-ai-engine-cpu-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "AI Engine ECS CPU utilization exceeds 70%"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  dimensions = local.ai_engine_ecs_dimensions
}

# AI ECS Memory > 75% (warning-only, no alarm_actions)
resource "aws_cloudwatch_metric_alarm" "ai_engine_memory" {
  alarm_name          = "${var.project_name}-ai-engine-memory-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "AI Engine ECS memory utilization exceeds 75% (warning)"
  treat_missing_data  = "notBreaching"

  dimensions = local.ai_engine_ecs_dimensions
}

# AI Service Connect RequestCount elevated
resource "aws_cloudwatch_metric_alarm" "ai_sc_requests_high" {
  alarm_name          = "${var.project_name}-ai-sc-requests-high-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RequestCount"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Sum"
  threshold           = 5000
  alarm_description   = "AI Engine Service Connect request count is elevated"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  dimensions = local.ai_sc_dimensions
}

# AI Service Connect HTTP 5xx count > 0
resource "aws_cloudwatch_metric_alarm" "ai_sc_5xx" {
  alarm_name          = "${var.project_name}-ai-sc-5xx-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "AI Engine Service Connect returning 5xx responses"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  dimensions = local.ai_sc_dimensions
}

# AI Service Connect 5xx rate > 1% (metric math)
resource "aws_cloudwatch_metric_alarm" "ai_sc_5xx_rate" {
  alarm_name          = "${var.project_name}-ai-sc-5xx-rate-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 1
  alarm_description   = "AI Engine Service Connect 5xx error rate exceeds 1%"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "e1"
    expression  = "(m_5xx / m_total) * 100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "m_5xx"

    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ECS"
      period      = 60
      stat        = "Sum"

      dimensions = local.ai_sc_dimensions
    }
  }

  metric_query {
    id = "m_total"

    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ECS"
      period      = 60
      stat        = "Sum"

      dimensions = local.ai_sc_dimensions
    }
  }
}

# AI p95 response time > 350ms via Service Connect TargetResponseTime
resource "aws_cloudwatch_metric_alarm" "ai_sc_p95_latency" {
  alarm_name          = "${var.project_name}-ai-sc-p95-latency-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ECS"
  period              = 60
  extended_statistic  = "p95"
  threshold           = 350
  alarm_description   = "AI Engine Service Connect p95 latency exceeds 350ms"
  alarm_actions       = local.ai_latency_scale_out_actions
  treat_missing_data  = "notBreaching"

  dimensions = local.ai_sc_dimensions
}

# AI p99 response time > 500ms via Service Connect TargetResponseTime
resource "aws_cloudwatch_metric_alarm" "ai_sc_p99_latency" {
  alarm_name          = "${var.project_name}-ai-sc-p99-latency-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ECS"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 500
  alarm_description   = "AI Engine Service Connect p99 latency exceeds 500ms"
  alarm_actions       = local.ai_latency_scale_out_actions
  treat_missing_data  = "notBreaching"

  dimensions = local.ai_sc_dimensions
}

# AI running task count < 2
resource "aws_cloudwatch_metric_alarm" "ai_engine_running_tasks" {
  alarm_name          = "${var.project_name}-ai-engine-running-tasks-${var.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = 2
  alarm_description   = "AI Engine running task count is below 2"
  alarm_actions       = local.scoped_alarm_actions
  treat_missing_data  = "breaching"

  dimensions = local.ai_engine_ecs_dimensions
}

# -----------------------------------------------------------------------------
# TASK: CPOA-102 | CDO-W12-057 - Service Connect proxy cost/headroom check
# OWNER: Tạ Hoàng Huy
# -----------------------------------------------------------------------------

locals {
  telemetry_api_service_name_custom = "${var.project_name}-${var.environment}-telemetry-api"
  worker_service_name_custom        = var.worker_service_name
  ai_service_name_custom            = var.ai_service_name
}

# =============================================================================
# 1. Telemetry API Alarms (Giám sát tải API hấp thụ telemetry)
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "telemetry_api_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-telemetry-api-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Telemetry API CPU utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.telemetry_api_service_name_custom
  }
}

resource "aws_cloudwatch_metric_alarm" "telemetry_api_memory_high" {
  alarm_name          = "${var.project_name}-${var.environment}-telemetry-api-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Telemetry API Memory utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.telemetry_api_service_name_custom
  }
}

# =============================================================================
# 2. Prediction Worker Alarms (Giám sát tải của worker chạy phân tích)
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "worker_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-worker-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Prediction Worker CPU utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.worker_service_name_custom
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_memory_high" {
  alarm_name          = "${var.project_name}-${var.environment}-worker-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Prediction Worker Memory utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.worker_service_name_custom
  }
}

# =============================================================================
# 3. AI Engine Alarms (Giám sát tải của AI serving container)
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "ai_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-ai-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi AI Engine CPU utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.ai_service_name_custom
  }
}

resource "aws_cloudwatch_metric_alarm" "ai_memory_high" {
  alarm_name          = "${var.project_name}-${var.environment}-ai-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi AI Engine Memory utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.ai_service_name_custom
  }
}
