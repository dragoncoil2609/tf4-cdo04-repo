# -----------------------------------------------------------------------------
# AI Engine ECS Task Definition and Service -- CPOA-48
#
# Scope:
# - ECS Fargate task definition for AI Engine.
# - IAM task role for S3 baseline access, KMS decrypt, CloudWatch metrics.
# - CloudWatch log group /ecs/ai-engine.
# - ECS service with Service Connect server discovery, circuit breaker,
#   private subnets, no public IP.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ai_engine" {
  name              = "/ecs/ai-engine"
  retention_in_days = var.app_log_retention_days

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-logs"
    Purpose = "ai-engine-logs"
  })
}

resource "aws_iam_role" "ai_engine_task_role" {
  name        = "${var.project_name}-${var.environment}-ai-engine-task-role"
  description = "Task role for AI Engine ECS task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEcsTasksAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-task-role"
    Purpose = "ai-engine-task-role"
  })
}

resource "aws_iam_policy" "ai_engine_task_policy" {
  name        = "${var.project_name}-${var.environment}-ai-engine-task-policy"
  description = "Allow AI Engine to read baseline files from S3 and publish CloudWatch metrics"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadBaselineEvidence"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.evidence_bucket_name}/baselines/*"
      },
      {
        Sid    = "AllowDecryptEvidence"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = var.kms_key_arn
      },
      {
        Sid    = "AllowPutMetricData"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-task-policy"
    Purpose = "ai-engine-permissions"
  })
}

resource "aws_iam_role_policy_attachment" "ai_engine_task_policy" {
  role       = aws_iam_role.ai_engine_task_role.name
  policy_arn = aws_iam_policy.ai_engine_task_policy.arn
}

resource "aws_ecs_task_definition" "ai_engine" {
  family                   = "${var.project_name}-${var.environment}-ai-engine"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = 512
  memory = 1024

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ai_engine_task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "ai-engine"
      image     = var.ai_engine_image
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = [
        {
          name  = "AWS_REGION"
          value = var.aws_region
        },
        {
          name  = "ENVIRONMENT"
          value = var.environment
        },
        {
          name  = "PORT"
          value = "8080"
        },
        {
          name  = "EVIDENCE_BUCKET_NAME"
          value = var.evidence_bucket_name
        },
        {
          name  = "AMP_REMOTE_WRITE_ENDPOINT"
          value = var.amp_remote_write_endpoint
        }
      ]

      healthCheck = {
        command  = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
        interval = 30
        timeout  = 5
        retries  = 3
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ai_engine.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ai-engine"
        }
      }
    }
  ])

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-task"
    Purpose = "ai-engine"
  })
}

resource "aws_ecs_service" "ai_engine" {
  name            = "${var.project_name}-${var.environment}-ai-engine"
  cluster         = aws_ecs_cluster.main.arn
  task_definition = aws_ecs_task_definition.ai_engine.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ai_engine_sg_id]
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "http"
      discovery_name = "ai-engine"
      client_alias {
        dns_name = "ai-engine"
        port     = 8080
      }
    }
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-service"
    Purpose = "ai-engine"
  })

  depends_on = [
    aws_iam_role_policy_attachment.ai_engine_task_policy,
    aws_cloudwatch_log_group.ai_engine
  ]
}
