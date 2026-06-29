# -----------------------------------------------------------------------------
# CDO-04 Compute Module -- Outputs
# -----------------------------------------------------------------------------

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "service_connect_namespace_name" {
  description = "ECS Service Connect namespace name"
  value       = aws_service_discovery_http_namespace.main.name
}

output "service_connect_namespace_arn" {
  description = "ECS Service Connect namespace ARN"
  value       = aws_service_discovery_http_namespace.main.arn
}

output "telemetry_api_task_definition_arn" {
  description = "Telemetry API ECS task definition ARN"
  value       = aws_ecs_task_definition.telemetry_api.arn
}

# TODO: service, ALB, scheduler, and ECR outputs belong to teammate-owned work.
output "prediction_worker_task_definition_arn" {
  description = "Prediction Worker ECS task definition ARN"
  value       = aws_ecs_task_definition.prediction_worker.arn
}

output "prediction_worker_task_role_arn" {
  description = "Prediction Worker ECS task role ARN"
  value       = aws_iam_role.prediction_worker_task_role.arn
}

output "prediction_worker_service_name" {
  description = "Prediction Worker ECS service name"
  value       = aws_ecs_service.prediction_worker.name
}

output "prediction_worker_log_group_name" {
  description = "CloudWatch log group for Prediction Worker"
  value       = aws_cloudwatch_log_group.prediction_worker.name
}

output "ai_service_name" {
  description = "AI Engine ECS service name"
  value       = "${var.project_name}-${var.environment}-ai-engine"
}

output "worker_service_name" {
  description = "Prediction Worker ECS service name"
  value       = aws_ecs_service.prediction_worker.name
}
