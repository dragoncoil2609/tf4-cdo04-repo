# -----------------------------------------------------------------------------
# CDO-04 Compute Module -- Main Resources
#
# Vinh-owned scope kept here:
#   - CPOA-41: ECS Cluster + Service Connect namespace
#   - CPOA-46: Telemetry API ECS task definition
#   - CPOA-50: ECS autoscaling policy placeholder (not implemented yet)
# -----------------------------------------------------------------------------

locals {
  cluster_name                = "${var.project_name}-${var.environment}-cluster"
  service_connect_namespace   = "${var.project_name}-${var.environment}.local"
  log_group_prefix            = "/ecs/${var.project_name}-${var.environment}"
  telemetry_api_task_cpu      = 512
  telemetry_api_task_memory   = 1024
  telemetry_api_container_url = var.telemetry_api_image_tag
}

# -----------------------------------------------------------------------------
# ECS Cluster (CPOA-41)
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# -----------------------------------------------------------------------------
# ECS Service Connect namespace (CPOA-41)
# -----------------------------------------------------------------------------
resource "aws_service_discovery_http_namespace" "main" {
  name        = local.service_connect_namespace
  description = "ECS Service Connect namespace for ${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# Telemetry API task definition support (CPOA-46)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "telemetry_api" {
  name              = "${local.log_group_prefix}-telemetry-api"
  retention_in_days = 14
}

resource "aws_iam_role" "ecs_execution" {
  name = "${var.project_name}-${var.environment}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "telemetry_api_task" {
  name = "${var.project_name}-${var.environment}-telemetry-api-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "telemetry_api_task" {
  name = "${var.project_name}-${var.environment}-telemetry-api-task"
  role = aws_iam_role.telemetry_api_task.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = var.amp_workspace_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = var.prediction_queue_arn
      }
    ]
  })
}

resource "aws_ecs_task_definition" "telemetry_api" {
  family                   = "${var.project_name}-${var.environment}-telemetry-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.telemetry_api_task_cpu
  memory                   = local.telemetry_api_task_memory

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.telemetry_api_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "telemetry-api"
      image     = local.telemetry_api_container_url
      essential = true
      portMappings = [
        {
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.telemetry_api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "telemetry-api"
        }
      }
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "AMP_REMOTE_WRITE_ENDPOINT", value = var.amp_remote_write_endpoint },
        { name = "PREDICTION_QUEUE_URL", value = var.prediction_queue_url },
      ]
      healthCheck = {
        command  = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
        interval = 30
        timeout  = 5
        retries  = 3
      }
    }
  ])
}

# -----------------------------------------------------------------------------
# TODO (CPOA-47): Prediction Worker task definition -- owned by Truong An.
# Placeholder only; no Worker task/service is implemented in Vinh scope.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# TODO (CPOA-48): AI Engine task definition -- owned by Truong An.
# Placeholder only; no AI task/service is implemented in Vinh scope.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# TODO (CPOA-49): ECS Service Connect config for AI -- owned by Truong An.
# Placeholder only; Worker -> AI Service Connect service/client_alias belongs here.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# TODO (CPOA-44): EventBridge Scheduler -- owned by Truong An.
# Placeholder only; scheduler role, schedule, retry policy, and DLQ wiring are not
# implemented in Vinh-owned Terraform slice.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# TODO (CPOA-50): ECS Autoscaling Policy -- Nguyễn Thành Vinh.
# Chưa triển khai. Add aws_appautoscaling_target and aws_appautoscaling_policy
# after ECS services are owned/defined by each service assignee.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# TODO (CPOA-78/CPOA-81): ECR repos, deploy wiring, ALB/service rollout, and
# smoke deployment pipeline are CI/CD/deployment-owned work, not Vinh scope.
# -----------------------------------------------------------------------------
