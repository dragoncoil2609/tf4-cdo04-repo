# -----------------------------------------------------------------------------
# ECS Autoscaling -- CPOA-50
#
# Telemetry API:    min=2  max=5  cpu70% target tracking + ALB p99 step policy
# Prediction Worker: min=1  max=5  step scaling policies (scale out / scale in)
# AI Engine:        min=2  max=4  cpu70% target tracking + latency step policy
# -----------------------------------------------------------------------------

# ── Telemetry API autoscaling ─────────────────────────────────────────────────

resource "aws_appautoscaling_target" "telemetry_api" {
  max_capacity       = 5
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.telemetry_api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "telemetry_api_cpu" {
  name               = "${var.project_name}-${var.environment}-telemetry-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.telemetry_api.resource_id
  scalable_dimension = aws_appautoscaling_target.telemetry_api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.telemetry_api.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "telemetry_api_memory" {
  name               = "${var.project_name}-${var.environment}-telemetry-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.telemetry_api.resource_id
  scalable_dimension = aws_appautoscaling_target.telemetry_api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.telemetry_api.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 75
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "telemetry_api_alb_p99_step" {
  name               = "${var.project_name}-${var.environment}-telemetry-alb-p99-step"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.telemetry_api.resource_id
  scalable_dimension = aws_appautoscaling_target.telemetry_api.scalable_dimension
  service_namespace  = aws_appautoscaling_target.telemetry_api.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

# ── Prediction Worker autoscaling ─────────────────────────────────────────────

resource "aws_appautoscaling_target" "prediction_worker" {
  max_capacity       = 5
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.prediction_worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "prediction_worker_scale_out" {
  name               = "${var.project_name}-${var.environment}-worker-scale-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.prediction_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.prediction_worker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.prediction_worker.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_appautoscaling_policy" "prediction_worker_scale_in" {
  name               = "${var.project_name}-${var.environment}-worker-scale-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.prediction_worker.resource_id
  scalable_dimension = aws_appautoscaling_target.prediction_worker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.prediction_worker.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

# ── AI Engine autoscaling ─────────────────────────────────────────────────────

resource "aws_appautoscaling_target" "ai_engine" {
  max_capacity       = var.ai_engine_max_capacity
  min_capacity       = var.ai_engine_min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.ai_engine.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ai_engine_cpu" {
  name               = "${var.project_name}-${var.environment}-ai-engine-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ai_engine.resource_id
  scalable_dimension = aws_appautoscaling_target.ai_engine.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ai_engine.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.ai_engine_autoscale_cpu_target
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "ai_engine_latency_step" {
  name               = "${var.project_name}-${var.environment}-ai-engine-latency-step"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ai_engine.resource_id
  scalable_dimension = aws_appautoscaling_target.ai_engine.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ai_engine.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}
