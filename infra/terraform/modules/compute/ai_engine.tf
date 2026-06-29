# -----------------------------------------------------------------------------
# AI Engine ECS Task Definition and Service -- CPOA-48 & CDO-W12-011 / CDO-W12-012 / CDO-W12-025
#
# Scope:
# - ECS Fargate task definition for AI Engine (0.5 vCPU / 1GB RAM).
# - IAM task role for S3 baseline access, KMS decrypt, CloudWatch metrics, SSM, and Secrets.
# - CloudWatch log group /ecs/ai-engine.
# - ECS service with Service Connect server discovery, circuit breaker,
#   private subnets, no public IP.
# - Python mock server cmd for sandbox verification.
# - CDO-W12-025: enforce SigV4-style signed Worker -> AI request.
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
  name = "${var.project_name}-${var.environment}-ai-engine-task-policy"

  # Keep this description aligned with the existing deployed policy to avoid
  # replacing the IAM managed policy during CDO-W12-025.
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

      # Mock AI server for sandbox verification.
      # /health remains open for ECS health checks.
      # /v1/predict enforces SigV4-style signed request from Prediction Worker.
      command = [
        "python",
        "-c",
        <<-PY
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os

ALLOWED_PRINCIPAL = os.environ.get("AI_ALLOWED_PRINCIPAL_ARN", "")
ENFORCE_SIGV4 = os.environ.get("AI_SIGV4_ENFORCE", "true").lower() == "true"

class H(BaseHTTPRequestHandler):
    def _json(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def _is_authorized(self):
        auth = self.headers.get("Authorization", "")
        amz_date = self.headers.get("X-Amz-Date", "")
        token = self.headers.get("X-Amz-Security-Token", "")
        worker_principal = self.headers.get("X-Worker-Principal", "")

        print("auth header prefix=" + auth[:32], flush=True)
        print("x-amz-date present=" + str(bool(amz_date)), flush=True)
        print("x-amz-security-token present=" + str(bool(token)), flush=True)
        print("x-worker-principal=" + worker_principal, flush=True)

        if not ENFORCE_SIGV4:
            return True, "auth disabled"

        if not auth.startswith("AWS4-HMAC-SHA256"):
            return False, "missing or invalid SigV4 Authorization header"

        if not amz_date:
            return False, "missing X-Amz-Date"

        if not token:
            return False, "missing X-Amz-Security-Token"

        if ALLOWED_PRINCIPAL and worker_principal != ALLOWED_PRINCIPAL:
            return False, "worker principal not allowed"

        return True, "authorized"

    def do_GET(self):
        print("GET " + self.path, flush=True)

        if self.path == "/health":
            self._json(200, {"status": "ok"})
            return

        self._json(404, {"error": "not_found"})

    def do_POST(self):
        print("POST " + self.path, flush=True)

        if self.path != "/v1/predict":
            self._json(404, {"error": "not_found"})
            return

        ok, reason = self._is_authorized()

        if not ok:
            print("sigv4 authorization failed: " + reason, flush=True)
            self._json(401, {
                "error": "unauthorized",
                "reason": reason
            })
            return

        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0)).decode()
        print("received signed predict request body=" + body, flush=True)

        self._json(200, {
            "anomaly": False,
            "severity": 0.0,
            "recommendation": {
                "action_verb": "INVESTIGATE",
                "target": "demo",
                "from_to": "none",
                "confidence": 0.5,
                "evidence_link": "placeholder"
            },
            "reasoning": "authorized SigV4 placeholder AI Engine",
            "audit_id": "sigv4-demo"
        })

HTTPServer(("0.0.0.0", 8080), H).serve_forever()
PY
      ]

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
        },
        {
          name  = "AI_SIGV4_ENFORCE"
          value = "true"
        },
        {
          name  = "AI_ALLOWED_PRINCIPAL_ARN"
          value = aws_iam_role.prediction_worker_task_role.arn
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
    aws_cloudwatch_log_group.ai_engine
  ]
}