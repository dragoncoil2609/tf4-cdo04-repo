# -----------------------------------------------------------------------------
# CDO-04 Compute Module -- Outputs
# -----------------------------------------------------------------------------

# ── ECS Cluster ────────────────────────────────────────────────────────────────

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

# ── ALB ───────────────────────────────────────────────────────────────────────

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.public.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch dimensions"
  value       = aws_lb.public.arn_suffix
}

output "telemetry_api_target_group_arn_suffix" {
  description = "Telemetry API target group ARN suffix for CloudWatch dimensions"
  value       = aws_lb_target_group.telemetry_api.arn_suffix
}

output "alb_dns_name" {
  description = "ALB public DNS name"
  value       = aws_lb.public.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID"
  value       = aws_lb.public.zone_id
}

output "alb_listener_arn" {
  description = "ALB HTTP listener ARN"
  value       = aws_lb_listener.http.arn
}

# ── Telemetry API Service ─────────────────────────────────────────────────────

output "telemetry_api_task_definition_arn" {
  description = "Telemetry API ECS task definition ARN"
  value       = aws_ecs_task_definition.telemetry_api.arn
}

output "telemetry_api_service_name" {
  description = "Telemetry API ECS service name"
  value       = aws_ecs_service.telemetry_api.name
}

output "telemetry_api_service_arn" {
  description = "Telemetry API ECS service ARN"
  value       = aws_ecs_service.telemetry_api.id
}

# ── Prediction Worker Service ─────────────────────────────────────────────────

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

# ── AI Engine Service ─────────────────────────────────────────────────────────

output "ai_service_name" {
  description = "AI Engine ECS service name"
  value       = aws_ecs_service.ai_engine.name
}

output "ai_service_arn" {
  description = "AI Engine ECS service ARN"
  value       = aws_ecs_service.ai_engine.id
}

output "ai_engine_task_definition_arn" {
  description = "AI Engine ECS task definition ARN"
  value       = aws_ecs_task_definition.ai_engine.arn
}

output "ai_engine_log_group_name" {
  description = "CloudWatch log group for AI Engine"
  value       = aws_cloudwatch_log_group.ai_engine.name
}

output "worker_service_name" {
  description = "Prediction Worker ECS service name"
  value       = aws_ecs_service.prediction_worker.name
}

# ── Autoscaling Step Policy ARNs for Observability ────────────────────────────

output "telemetry_api_alb_p99_step_policy_arn" {
  description = "Telemetry API ALB p99 step scaling policy ARN"
  value       = aws_appautoscaling_policy.telemetry_api_alb_p99_step.arn
}

output "prediction_worker_scale_out_policy_arn" {
  description = "Prediction Worker scale-out step scaling policy ARN"
  value       = aws_appautoscaling_policy.prediction_worker_scale_out.arn
}

output "prediction_worker_scale_in_policy_arn" {
  description = "Prediction Worker scale-in step scaling policy ARN"
  value       = aws_appautoscaling_policy.prediction_worker_scale_in.arn
}

output "ai_engine_latency_step_policy_arn" {
  description = "AI Engine latency step scaling policy ARN"
  value       = aws_appautoscaling_policy.ai_engine_latency_step.arn
}

