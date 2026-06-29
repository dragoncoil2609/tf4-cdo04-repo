# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Operational Alerting (CPOA-88) & Auditing (CPOA-103)
# -----------------------------------------------------------------------------

locals {
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
}

# -----------------------------------------------------------------------------
# Operational SNS topic and email subscription
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "operational_alerts" {
  name = "${var.project_name}-operational-alerts-${var.environment}"
}

resource "aws_sns_topic_subscription" "operational_email" {
  topic_arn = aws_sns_topic.operational_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
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
