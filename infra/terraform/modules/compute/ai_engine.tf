# -----------------------------------------------------------------------------
# AI Engine ECS Task Definition -- CDO-W12-011 / CDO-W12-012
#
# Scope:
# - ECS Fargate task definition for AI Engine.
# - ECS service with desired count = 2.
# - ECS Service Auto Scaling min = 2, max = 4.
# - Container port 8080.
# - Health check path /health.
# - CloudWatch log group /ecs/ai-engine.
# - Optional S3 baseline read access from baselines/ prefix.
# - Service Connect registration for private name: ai-engine:8080.
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
  description = "Allow AI Engine to read baseline files from S3 baselines prefix and decrypt config if required"

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

  # Acceptance criteria: 0.5 vCPU / 1GB
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

      # Placeholder FastAPI-like HTTP server for infrastructure validation.
      # It exposes /health and /v1/predict until the real AI image is ready.
      command = [
        "python",
        "-c",
        "from http.server import BaseHTTPRequestHandler, HTTPServer\nimport json\nclass H(BaseHTTPRequestHandler):\n    def do_GET(self):\n        print('GET ' + self.path, flush=True)\n        if self.path == '/health':\n            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{\"status\":\"ok\"}')\n        else:\n            self.send_response(404); self.end_headers()\n    def do_POST(self):\n        print('POST ' + self.path, flush=True)\n        if self.path == '/v1/predict':\n            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps({'anomaly': False, 'severity': 0.0, 'recommendation': {'action_verb': 'INVESTIGATE', 'target': 'demo', 'from_to': 'none', 'confidence': 0.5, 'evidence_link': 'placeholder'}, 'reasoning': 'placeholder ai engine', 'audit_id': 'placeholder'}).encode())\n        else:\n            self.send_response(404); self.end_headers()\nHTTPServer(('0.0.0.0', 8080), H).serve_forever()"
      ]

      portMappings = [
        {
          name          = "ai-engine"
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

  # Acceptance criteria: min desired count = 2
  desired_count = var.ai_engine_desired_count
  launch_type   = "FARGATE"

  enable_execute_command = var.enable_execute_command

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "ai-engine"
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

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ai_engine_sg_id]
    assign_public_ip = false
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

resource "aws_appautoscaling_target" "ai_engine" {
  max_capacity       = var.ai_engine_max_capacity
  min_capacity       = var.ai_engine_min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.ai_engine.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [
    aws_ecs_service.ai_engine
  ]
}

resource "aws_appautoscaling_policy" "ai_engine_cpu" {
  name               = "${var.project_name}-${var.environment}-ai-engine-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ai_engine.resource_id
  scalable_dimension = aws_appautoscaling_target.ai_engine.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ai_engine.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = var.ai_engine_autoscale_cpu_target

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}