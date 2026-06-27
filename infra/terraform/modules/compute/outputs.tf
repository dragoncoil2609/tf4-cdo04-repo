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

output "alb_dns_name" {
  description = "Public ALB DNS name for telemetry ingestion"
  value       = aws_lb.public.dns_name
}

output "alb_arn" {
  description = "Public ALB ARN"
  value       = aws_lb.public.arn
}

output "alb_target_group_arn" {
  description = "ALB target group ARN for telemetry API"
  value       = aws_lb_target_group.telemetry_api.arn
}

output "telemetry_api_service_name" {
  description = "ECS service name for Telemetry Ingestion API"
  value       = aws_ecs_service.telemetry_api.name
}

output "prediction_worker_service_name" {
  description = "ECS service name for Prediction Worker"
  value       = aws_ecs_service.prediction_worker.name
}

output "ai_engine_service_name" {
  description = "ECS service name for AI Engine"
  value       = aws_ecs_service.ai_engine.name
}

output "adot_collector_service_name" {
  description = "ECS service name for ADOT/Prometheus Collector"
  value       = aws_ecs_service.adot_collector.name
}

output "prediction_scheduler_arn" {
  description = "EventBridge Scheduler ARN for prediction jobs"
  value       = try(aws_scheduler_schedule.prediction[0].arn, "")
}

output "telemetry_api_ecr_repository_url" {
  description = "ECR repository URL for Telemetry API"
  value       = aws_ecr_repository.telemetry_api.repository_url
}

output "prediction_worker_ecr_repository_url" {
  description = "ECR repository URL for Prediction Worker"
  value       = aws_ecr_repository.prediction_worker.repository_url
}

output "ai_engine_ecr_repository_url" {
  description = "ECR repository URL for AI Engine"
  value       = aws_ecr_repository.ai_engine.repository_url
}
