# -----------------------------------------------------------------------------
# AI Engine ECS Task Definition and Service -- CPOA-48 & CDO-W12-011 / CDO-W12-012
#
# Scope:
# - ECS Fargate task definition for AI Engine (0.5 vCPU / 1GB RAM).
# - IAM task role for S3 baseline access, KMS decrypt, CloudWatch metrics, SSM, and Secrets.
# - CloudWatch log group /ecs/ai-engine.
# - ECS service with Service Connect server discovery, circuit breaker,
#   private subnets, no public IP.
# - Real AI Engine app runs via Dockerfile CMD.
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
  description = "Allow AI Engine to read baseline files from S3, read SSM params, Secrets, decrypt and publish CloudWatch metrics"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowListBaselinePrefix"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = "arn:aws:s3:::${var.baseline_s3_bucket_name}"
        Condition = {
          StringLike = {
            "s3:prefix" = [
              var.baseline_s3_prefix,
              "${var.baseline_s3_prefix}*"
            ]
          }
        }
      },
      {
        Sid    = "AllowReadBaselineObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.baseline_s3_bucket_name}/${var.baseline_s3_prefix}*"
      },
      {
        Sid    = "AllowReadBaselineEvidence"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.evidence_bucket_name}/baselines/*"
      },
      {
        Sid    = "AllowReadRuntimeParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = var.ai_engine_ssm_parameter_arns
      },
      {
        Sid    = "AllowReadSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = var.ai_engine_secret_arns
      },
      {
        Sid    = "AllowDecryptConfigSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
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
  cpu                      = 512
  memory                   = 1024

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
          hostPort      = 8080
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).read()\""
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }

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
        },
        {
          name  = "BASELINE_BACKEND"
          value = "s3"
        },
        {
          name  = "BASELINE_S3_BUCKET"
          value = var.baseline_s3_bucket_name
        },
        {
          name  = "BASELINE_S3_PREFIX"
          value = var.baseline_s3_prefix
        },
        {
          name  = "AI_SERVICE_NAME"
          value = "ai-engine"
        },
        {
          name  = "AI_PREDICT_PATH"
          value = "/v1/predict"
        },
        {
          name  = "AI_HEALTH_PATH"
          value = "/health"
        }
      ]

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
  desired_count   = var.ai_engine_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = var.enable_execute_command

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ai_engine.arn
    container_name   = "ai-engine"
    container_port   = var.app_port
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

    log_configuration {
      log_driver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ai_engine.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "service-connect"
      }
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-service"
    Purpose = "ai-engine"
  })

  depends_on = [
    aws_iam_role_policy_attachment.ai_engine_task_policy,
    aws_cloudwatch_log_group.ai_engine,
    aws_lb_listener_rule.predict
  ]
}
