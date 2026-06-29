# -----------------------------------------------------------------------------
# Telemetry API ECS Task Definition and Service -- CPOA-46 / CPOA-45 / CPOA-78
#
# Scope:
# - ECS Fargate task definition for Telemetry Ingestion API (0.5 vCPU / 1GB RAM).
# - IAM task role for AMP Remote Write + SQS SendMessage.
# - CloudWatch log group /ecs/telemetry-api.
# - ECS service with deployment circuit breaker, private subnets, no public IP,
#   fronted by ALB target group (alb.tf).
# -----------------------------------------------------------------------------

locals {
  telemetry_api_task_cpu      = 512
  telemetry_api_task_memory   = 1024
  telemetry_api_container_url = var.telemetry_api_image_tag
}

resource "aws_cloudwatch_log_group" "telemetry_api" {
  name              = "/ecs/telemetry-api"
  retention_in_days = 14
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

resource "aws_ecs_service" "telemetry_api" {
  name            = "${var.project_name}-${var.environment}-telemetry-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.telemetry_api.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.telemetry_api_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.telemetry_api.arn
    container_name   = "telemetry-api"
    container_port   = var.app_port
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}
