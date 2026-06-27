# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Outputs
#
# Matches root module expected outputs: dashboard_url, alarm_arns.
# -----------------------------------------------------------------------------

output "dashboard_url" {
  description = "CloudWatch dashboard URL for the observability dashboard"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/detail/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "alarm_arns" {
  description = "List of all CloudWatch alarm ARNs created by this module"
  value = compact([
    aws_cloudwatch_metric_alarm.alb_target_5xx.arn,
    aws_cloudwatch_metric_alarm.alb_target_latency_p95.arn,
    aws_cloudwatch_metric_alarm.alb_unhealthy_hosts.arn,
    aws_cloudwatch_metric_alarm.ecs_telemetry_api_cpu.arn,
    aws_cloudwatch_metric_alarm.ecs_prediction_worker_cpu.arn,
    aws_cloudwatch_metric_alarm.ecs_ai_engine_cpu.arn,
    aws_cloudwatch_metric_alarm.ecs_ai_engine_memory.arn,
    aws_cloudwatch_metric_alarm.sqs_prediction_queue_depth.arn,
    aws_cloudwatch_metric_alarm.sqs_prediction_dlq_depth.arn,
    aws_cloudwatch_metric_alarm.sqs_prediction_queue_age.arn,
    aws_cloudwatch_metric_alarm.dynamodb_audit_read_throttles.arn,
    aws_cloudwatch_metric_alarm.dynamodb_audit_write_throttles.arn,
    aws_cloudwatch_metric_alarm.dynamodb_audit_system_errors.arn,
  ])
}

output "sns_topic_arn" {
  description = "SNS topic ARN for observability alarm actions (module-local, not the data module SNS)"
  value       = aws_sns_topic.alarms.arn
}

output "budget_name" {
  description = "AWS Budget name"
  value       = aws_budgets_budget.monthly.name
}
