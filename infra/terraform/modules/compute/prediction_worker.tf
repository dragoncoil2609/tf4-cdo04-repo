# -----------------------------------------------------------------------------
# Prediction Worker ECS Task Definition -- CDO-W12-010 / CDO-W12-012
#
# Scope:
# - ECS Fargate task definition for Prediction Worker.
# - IAM task role for SQS/AMP/DynamoDB/SNS/Secrets/SSM.
# - CloudWatch log group /ecs/prediction-worker.
# - ECS service runs in private subnets with no public IP.
# - Service Connect client config to call AI by http://ai-engine:8080.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_log_group" "prediction_worker" {
  name              = "/ecs/prediction-worker"
  retention_in_days = var.app_log_retention_days

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-prediction-worker-logs"
    Purpose = "prediction-worker-logs"
  })
}

resource "aws_iam_role" "prediction_worker_task_role" {
  name        = "${var.project_name}-${var.environment}-prediction-worker-task-role"
  description = "Task role for Prediction Worker ECS task"

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
    Name    = "${var.project_name}-${var.environment}-prediction-worker-task-role"
    Purpose = "prediction-worker-task-role"
  })
}

resource "aws_iam_policy" "prediction_worker_task_policy" {
  name        = "${var.project_name}-${var.environment}-prediction-worker-task-policy"
  description = "Allow Prediction Worker to consume SQS, query AMP, audit to DynamoDB, publish SNS, and read config/secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadPredictionQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = var.prediction_queue_arn
      },
      {
        Sid    = "AllowQueryAMP"
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetLabels",
          "aps:GetMetricMetadata",
          "aps:GetSeries"
        ]
        Resource = var.amp_workspace_arn
      },
      {
        Sid    = "AllowAuditAndPolicyDynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem",
          "dynamodb:DescribeTable"
        ]
        Resource = var.worker_dynamodb_table_arns
      },
      {
        Sid    = "AllowPublishAlerts"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = var.alert_topic_arn
      },
      {
        Sid    = "AllowReadRuntimeParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = var.worker_ssm_parameter_arns
      },
      {
        Sid    = "AllowReadSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = var.worker_secret_arns
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
    Name    = "${var.project_name}-${var.environment}-prediction-worker-task-policy"
    Purpose = "prediction-worker-permissions"
  })
}

resource "aws_iam_role_policy_attachment" "prediction_worker_task_policy" {
  role       = aws_iam_role.prediction_worker_task_role.name
  policy_arn = aws_iam_policy.prediction_worker_task_policy.arn
}

resource "aws_ecs_task_definition" "prediction_worker" {
  family                   = "${var.project_name}-${var.environment}-prediction-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # Acceptance criteria: 0.5 vCPU / 1GB
  cpu    = 512
  memory = 1024

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.prediction_worker_task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "prediction-worker"
      image     = var.prediction_worker_image
      essential = true

      # Graceful shutdown support for SQS message processing.
      # ECS sends SIGTERM first, then waits stopTimeout before SIGKILL.
      stopTimeout = var.prediction_worker_stop_timeout_seconds

      healthCheck = {
        command     = ["CMD-SHELL", "pgrep -f 'python app.py' || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
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
          name  = "PREDICTION_QUEUE_URL"
          value = var.prediction_queue_url
        },
        {
          name  = "SQS_QUEUE_URL"
          value = var.prediction_queue_url
        },
        {
          name  = "AMP_QUERY_ENDPOINT"
          value = var.amp_query_endpoint
        },
        {
          name  = "AUDIT_TABLE_NAME"
          value = var.audit_table_name
        },
        {
          name  = "DYNAMODB_AUDIT_TABLE"
          value = var.audit_table_name
        },
        {
          name  = "AI_SERVICE_NAME"
          value = var.ai_service_name
        },
        {
          name  = "AI_ENGINE_BASE_URL"
          value = "http://ai-engine:8080"
        },
        {
          name  = "AI_PREDICT_PATH"
          value = var.ai_predict_path
        },
        {
          name  = "AI_ENGINE_ENDPOINT"
          value = "http://ai-engine:8080/v1/predict"
        },
        {
          name  = "LOOKBACK_WINDOW_MINUTES"
          value = tostring(var.lookback_window_minutes)
        },
        {
          name  = "AI_TIMEOUT_SECONDS"
          value = "2"
        },
        {
          name  = "GRACEFUL_SHUTDOWN_SECONDS"
          value = tostring(var.prediction_worker_stop_timeout_seconds)
        },
        {
          name  = "AI_SIGV4_CONFIG_SECRET_ARN"
          value = var.ai_sigv4_config_secret_arn
        },
        {
          name  = "ALERT_TOPIC_ARN"
          value = "arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.project_name}-operational-alerts-${var.environment}"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.prediction_worker.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "prediction-worker"
        }
      }
    }
  ])

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-prediction-worker-task"
    Purpose = "prediction-worker"
  })
}

resource "aws_ecs_service" "prediction_worker" {
  name            = "${var.project_name}-${var.environment}-prediction-worker"
  cluster         = aws_ecs_cluster.main.arn
  task_definition = aws_ecs_task_definition.prediction_worker.arn
  desired_count   = var.prediction_worker_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = var.enable_execute_command

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    log_configuration {
      log_driver = "awslogs"

      options = {
        awslogs-group         = aws_cloudwatch_log_group.prediction_worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "service-connect"
      }
    }
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.prediction_worker_sg_id]
    assign_public_ip = false
  }
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-prediction-worker-service"
    Purpose = "prediction-worker"
  })

  depends_on = [
    aws_iam_role_policy_attachment.prediction_worker_task_policy,
    aws_cloudwatch_log_group.prediction_worker
  ]
}