# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Outputs
# -----------------------------------------------------------------------------

output "budget_alert_topic_arn" {
  description = "SNS topic ARN for budget alerts"
  value       = aws_sns_topic.budget_alert.arn
}

output "budget_alert_topic_name" {
  description = "SNS topic name for budget alerts"
  value       = aws_sns_topic.budget_alert.name
}

output "cost_breaker_role_arn" {
  description = "IAM role ARN for the cost breaker Lambda"
  value       = aws_iam_role.cost_breaker.arn
}

output "cost_dashboard_name" {
  description = "CloudWatch cost dashboard name"
  value       = aws_cloudwatch_dashboard.cost_dashboard.dashboard_name
}