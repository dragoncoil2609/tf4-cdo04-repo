# -----------------------------------------------------------------------------
# CDO-04 Compute Module -- Main Resources
# -----------------------------------------------------------------------------

locals {
  ecr_name_telemetry_api     = "${var.project_name}-${var.environment}-telemetry-api"
  ecr_name_prediction_worker = "${var.project_name}-${var.environment}-prediction-worker"
  ecr_name_ai_engine         = "${var.project_name}-${var.environment}-ai-engine"

  cluster_name = "${var.project_name}-${var.environment}-cluster"

  service_name_telemetry_api     = "${var.project_name}-${var.environment}-telemetry-api"
  service_name_prediction_worker = "${var.project_name}-${var.environment}-prediction-worker"
  service_name_ai_engine         = "${var.project_name}-${var.environment}-ai-engine"
  service_name_adot_collector    = "${var.project_name}-${var.environment}-adot-collector"

  service_connect_namespace = "${var.project_name}-${var.environment}.local"
  log_group_prefix          = "/ecs/${var.project_name}-${var.environment}"

  adot_image = var.adot_collector_image_tag != "" ? var.adot_collector_image_tag : "public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0"

  task_cpu    = 512
  task_memory = 1024

  # ADOT collector config as YAML env var (boring, not overbuilt)
  adot_config = yamlencode({
    receivers = {
      otlp = {
        protocols = {
          grpc = { endpoint = "0.0.0.0:4317" }
          http = { endpoint = "0.0.0.0:4318" }
        }
      }
    }
    processors = {
      batch = {
        timeout         = "5s"
        send_batch_size = 1024
      }
    }
    extensions = {
      sigv4auth = {
        region  = var.aws_region
        service = "aps"
      }
    }
    exporters = {
      prometheusremotewrite = {
        endpoint = var.amp_remote_write_endpoint
        auth     = { authenticator = "sigv4auth" }
      }
    }
    service = {
      extensions = ["sigv4auth"]
      pipelines = {
        metrics = {
          receivers  = ["otlp"]
          processors = ["batch"]
          exporters  = ["prometheusremotewrite"]
        }
      }
    }
  })
}

# -----------------------------------------------------------------------------
# ECR Repositories
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "telemetry_api" {
  name                 = local.ecr_name_telemetry_api
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.environment == "sandbox" ? true : false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_repository" "prediction_worker" {
  name                 = local.ecr_name_prediction_worker
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.environment == "sandbox" ? true : false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_repository" "ai_engine" {
  name                 = local.ecr_name_ai_engine
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.environment == "sandbox" ? true : false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "default" {
  for_each = {
    telemetry_api     = aws_ecr_repository.telemetry_api.name
    prediction_worker = aws_ecr_repository.prediction_worker.name
    ai_engine         = aws_ecr_repository.ai_engine.name
  }

  repository = each.value

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# ECS Cluster
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloud_watch_encryption_enabled = true
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs_exec.name
      }
    }
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Groups
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "${local.log_group_prefix}-ecs-exec"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "telemetry_api" {
  name              = "${local.log_group_prefix}-telemetry-api"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "prediction_worker" {
  name              = "${local.log_group_prefix}-prediction-worker"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "ai_engine" {
  name              = "${local.log_group_prefix}-ai-engine"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "ai_audit" {
  name              = "${local.log_group_prefix}-ai-engine-audit"
  retention_in_days = 365
}

resource "aws_cloudwatch_log_group" "adot_collector" {
  name              = "${local.log_group_prefix}-adot-collector"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "service_connect" {
  name              = "${local.log_group_prefix}-service-connect"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# Service Discovery HTTP Namespace (ECS Service Connect)
# -----------------------------------------------------------------------------
resource "aws_service_discovery_http_namespace" "main" {
  name        = local.service_connect_namespace
  description = "ECS Service Connect namespace for ${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# IAM: ECS Execution Role
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# IAM: Telemetry API Task Role
# -----------------------------------------------------------------------------
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
      },
      {
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        # cloudwatch:PutMetricData does not support resource-level permissions.
        # AWS requires Resource = "*" for this action.
        # See: https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazoncloudwatch.html
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["arn:aws:s3:::${var.evidence_bucket_name}/failure-buffer/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.evidence_kms_key_arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM: ADOT Collector Task Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "adot_collector_task" {
  name = "${var.project_name}-${var.environment}-adot-collector-task"
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

resource "aws_iam_role_policy" "adot_collector_task" {
  name = "${var.project_name}-${var.environment}-adot-collector-task"
  role = aws_iam_role.adot_collector_task.name
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
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.adot_collector.arn}:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM: Prediction Worker Task Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "prediction_worker_task" {
  name = "${var.project_name}-${var.environment}-prediction-worker-task"
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

resource "aws_iam_role_policy" "prediction_worker_task" {
  name = "${var.project_name}-${var.environment}-prediction-worker-task"
  role = aws_iam_role.prediction_worker_task.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage", "sqs:DeleteMessage",
          "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"
        ]
        Resource = var.prediction_queue_arn
      },
      {
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics", "aps:GetSeries",
          "aps:GetLabels", "aps:GetMetricMetadata"
        ]
        Resource = var.amp_workspace_arn
      },
      {
        # DynamoDB table ARNs use wildcard account ID because the compute module
        # does not have a data.aws_caller_identity source. This still scopes to
        # specific table names, providing effective table-level isolation.
        # Tightening to full account-qualified ARN requires plumbing account ID
        # through module variables (avoided for v1 simplicity).
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:GetItem"]
        Resource = [
          "arn:aws:dynamodb:${var.aws_region}:*:table/${var.audit_table_name}",
          "arn:aws:dynamodb:${var.aws_region}:*:table/${var.policy_table_name}",
          "arn:aws:dynamodb:${var.aws_region}:*:table/${var.audit_table_name}/index/prediction-index"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.sns_alert_topic_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.ai_service_config_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["arn:aws:s3:::${var.evidence_bucket_name}/smoke/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.evidence_kms_key_arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM: AI Engine Task Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ai_engine_task" {
  name = "${var.project_name}-${var.environment}-ai-engine-task"
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

resource "aws_iam_role_policy" "ai_engine_task" {
  name = "${var.project_name}-${var.environment}-ai-engine-task"
  role = aws_iam_role.ai_engine_task.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${var.baseline_bucket_name}/baselines/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.evidence_kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.ai_service_config_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.ai_audit.arn}:*"]
      },
      {
        # cloudwatch:PutMetricData does not support resource-level permissions.
        # AWS requires Resource = "*" for this action.
        # See: https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazoncloudwatch.html
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# ADOT Collector Security Group
#
# Allows OTLP gRPC (4317) and HTTP (4318) ingress from app services.
# Egress to all destinations (AMP, etc.) is unrestricted.
# -----------------------------------------------------------------------------
resource "aws_security_group" "adot_collector" {
  name        = "${var.project_name}-${var.environment}-adot-collector"
  description = "ADOT Collector ECS tasks security group"
  vpc_id      = var.vpc_id

  ingress {
    from_port = 4317
    to_port   = 4317
    protocol  = "tcp"
    security_groups = [
      var.ecs_api_security_group_id,
      var.worker_security_group_id,
      var.ai_engine_security_group_id,
    ]
    description = "Allow OTLP gRPC from app services"
  }

  ingress {
    from_port = 4318
    to_port   = 4318
    protocol  = "tcp"
    security_groups = [
      var.ecs_api_security_group_id,
      var.worker_security_group_id,
      var.ai_engine_security_group_id,
    ]
    description = "Allow OTLP HTTP from app services"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-adot-collector"
  }
}

# -----------------------------------------------------------------------------
# ECS Task Definition: Telemetry API
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "telemetry_api" {
  family                   = "${var.project_name}-${var.environment}-telemetry-api"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.task_cpu
  memory                   = local.task_memory

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.telemetry_api_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "telemetry-api"
      image     = var.telemetry_api_image_tag
      essential = true
      portMappings = [
        {
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]
      networkMode = "awsvpc"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.telemetry_api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "telemetry-api"
        }
      }
      environment = [
        { name = "MOCK_ROLE", value = "api" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "AMP_REMOTE_WRITE_ENDPOINT", value = var.amp_remote_write_endpoint },
        { name = "PREDICTION_QUEUE_URL", value = var.prediction_queue_url },
        { name = "EVIDENCE_BUCKET_NAME", value = var.evidence_bucket_name },
        { name = "EVIDENCE_KMS_KEY_ARN", value = var.evidence_kms_key_arn },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://adot-collector:4318" },
        { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf" },
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
# ECS Task Definition: Prediction Worker
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "prediction_worker" {
  family                   = "${var.project_name}-${var.environment}-prediction-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.task_cpu
  memory                   = local.task_memory

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.prediction_worker_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "prediction-worker"
      image        = var.prediction_worker_image_tag
      essential    = true
      portMappings = []
      networkMode  = "awsvpc"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.prediction_worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "prediction-worker"
        }
      }
      environment = [
        { name = "MOCK_ROLE", value = "worker" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "EVIDENCE_BUCKET_NAME", value = var.evidence_bucket_name },
        { name = "PREDICTION_QUEUE_URL", value = var.prediction_queue_url },
        { name = "AMP_QUERY_ENDPOINT", value = var.amp_query_endpoint },
        { name = "AMP_WORKSPACE_ARN", value = var.amp_workspace_arn },
        { name = "AUDIT_TABLE_NAME", value = var.audit_table_name },
        { name = "POLICY_TABLE_NAME", value = var.policy_table_name },
        { name = "SNS_ALERT_TOPIC_ARN", value = var.sns_alert_topic_arn },
        { name = "AI_SERVICE_CONFIG_SECRET_ARN", value = var.ai_service_config_secret_arn },
        { name = "AI_ENGINE_URL", value = "http://ai-engine:8080" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://adot-collector:4318" },
        { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf" },
      ]
      healthCheck = {
        command  = ["CMD", "true"]
        interval = 30
        timeout  = 5
        retries  = 3
      }
    }
  ])
}

# -----------------------------------------------------------------------------
# ECS Task Definition: AI Engine
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "ai_engine" {
  family                   = "${var.project_name}-${var.environment}-ai-engine"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.task_cpu
  memory                   = local.task_memory

  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ai_engine_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "ai-engine"
      image     = var.ai_engine_image_tag
      essential = true
      portMappings = [
        {
          name          = "http"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]
      networkMode = "awsvpc"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ai_engine.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ai-engine"
        }
      }
      environment = [
        { name = "MOCK_ROLE", value = "ai" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "BASELINE_BACKEND", value = "s3" },
        { name = "BASELINE_S3_BUCKET", value = var.baseline_bucket_name },
        { name = "BASELINE_S3_PREFIX", value = "baselines/" },
        { name = "AUDIT_BACKEND", value = "cloudwatch" },
        { name = "AUDIT_LOG_GROUP", value = aws_cloudwatch_log_group.ai_audit.name },
        { name = "AI_SERVICE_CONFIG_SECRET_ARN", value = var.ai_service_config_secret_arn },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://adot-collector:4318" },
        { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf" },
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])
}

# -----------------------------------------------------------------------------
# ECS Task Definition: ADOT Collector
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "adot_collector" {
  family                   = "${var.project_name}-${var.environment}-adot-collector"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.adot_collector_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "adot-collector"
      image     = local.adot_image
      essential = true
      portMappings = [
        {
          name          = "grpc-otlp"
          containerPort = 4317
          protocol      = "tcp"
        },
        {
          name          = "http-otlp"
          containerPort = 4318
          protocol      = "tcp"
        }
      ]
      networkMode = "awsvpc"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.adot_collector.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "adot-collector"
        }
      }
      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "AMP_REMOTE_WRITE_ENDPOINT", value = var.amp_remote_write_endpoint },
        { name = "PREDICTION_QUEUE_URL", value = var.prediction_queue_url },
        { name = "AOT_CONFIG_CONTENT", value = local.adot_config },
      ]
    }
  ])
}

# -----------------------------------------------------------------------------
# ECS Service: Telemetry API
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "telemetry_api" {
  name            = local.service_name_telemetry_api
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.telemetry_api.arn
  desired_count   = var.enable_services ? 2 : 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_api_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.telemetry_api.arn
    container_name   = "telemetry-api"
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service_connect.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "telemetry-api-sc"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# ECS Service: Prediction Worker
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "prediction_worker" {
  name            = local.service_name_prediction_worker
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.prediction_worker.arn
  desired_count   = var.enable_services ? 1 : 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.worker_security_group_id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service_connect.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "worker-sc"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# ECS Service: AI Engine (Service Connect client_alias for Worker access)
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "ai_engine" {
  name            = local.service_name_ai_engine
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.ai_engine.arn
  desired_count   = var.enable_services ? 2 : 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ai_engine_security_group_id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service_connect.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ai-engine-sc"
      }
    }

    service {
      port_name      = "http"
      discovery_name = "ai-engine"

      client_alias {
        dns_name = "ai-engine"
        port     = 8080
      }
    }
  }
}

# -----------------------------------------------------------------------------
# ECS Service: ADOT Collector
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "adot_collector" {
  name            = local.service_name_adot_collector
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.adot_collector.arn
  desired_count   = var.enable_services ? 1 : 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.adot_collector.id]
    assign_public_ip = false
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.service_connect.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "adot-sc"
      }
    }

    service {
      port_name      = "http-otlp"
      discovery_name = "adot-collector"

      client_alias {
        dns_name = "adot-collector"
        port     = 4318
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer (public, /v1/ingest only)
# -----------------------------------------------------------------------------
resource "aws_lb" "public" {
  name               = "${var.project_name}-${var.environment}-public"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod" ? true : false
  drop_invalid_header_fields = true
}

# ALB Target Group (Telemetry API)
resource "aws_lb_target_group" "telemetry_api" {
  name        = "${var.project_name}-${var.environment}-tg-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}


# -----------------------------------------------------------------------------
# ALB Security Group Ingress Rules
#
# The networking module creates the ALB SG with egress only. This module owns
# ingress because it receives allowed_ingress_cidrs and acm_certificate_arn.
# -----------------------------------------------------------------------------
resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.allowed_ingress_cidrs
  security_group_id = var.alb_security_group_id
  description       = "Allow HTTP from allowed ingress CIDRs"
}

resource "aws_security_group_rule" "alb_ingress_https" {
  count = var.acm_certificate_arn != "" ? 1 : 0

  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.allowed_ingress_cidrs
  security_group_id = var.alb_security_group_id
  description       = "Allow HTTPS from allowed ingress CIDRs"
}

# HTTP listener: route /v1/ingest to Telemetry API, 404 for everything else
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "ingest_path_http" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type = "forward"
    forward {
      target_group {
        arn = aws_lb_target_group.telemetry_api.arn
      }
    }
  }

  condition {
    path_pattern {
      values = ["/v1/ingest*"]
    }
  }
}

# HTTPS listener (only if certificate ARN is provided)
resource "aws_lb_listener" "https" {
  count = var.acm_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "ingest_path_https" {
  count = var.acm_certificate_arn != "" ? 1 : 0

  listener_arn = aws_lb_listener.https[0].arn
  priority     = 1

  action {
    type = "forward"
    forward {
      target_group {
        arn = aws_lb_target_group.telemetry_api.arn
      }
    }
  }

  condition {
    path_pattern {
      values = ["/v1/ingest*"]
    }
  }
}

# -----------------------------------------------------------------------------
# EventBridge Scheduler: Prediction Job every 5 minutes
# -----------------------------------------------------------------------------
resource "aws_iam_role" "scheduler" {
  name = "${var.project_name}-${var.environment}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "scheduler.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.project_name}-${var.environment}-scheduler"
  role = aws_iam_role.scheduler.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["sqs:SendMessage"]
        Resource = compact([
          var.prediction_queue_arn,
          var.scheduler_dlq_arn,
        ])
      }
    ]
  })
}

resource "aws_scheduler_schedule" "prediction" {
  name       = "${var.project_name}-${var.environment}-prediction-5min"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = "rate(5 minutes)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = var.prediction_queue_arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 300
    }

    dynamic "dead_letter_config" {
      for_each = var.scheduler_dlq_arn != "" ? [1] : []
      content {
        arn = var.scheduler_dlq_arn
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Precondition: enforce HTTPS in non-sandbox environments
# -----------------------------------------------------------------------------
resource "terraform_data" "https_check" {
  lifecycle {
    precondition {
      condition     = var.environment == "sandbox" || var.acm_certificate_arn != ""
      error_message = "acm_certificate_arn is required for non-sandbox environments. Set it to a valid ACM certificate ARN in us-east-1."
    }
  }
}