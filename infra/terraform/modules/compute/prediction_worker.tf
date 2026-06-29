# -----------------------------------------------------------------------------
# Prediction Worker ECS Task Definition -- CDO-W12-010 / CDO-W12-012 / CDO-W12-025
#
# Scope:
# - ECS Fargate task definition for Prediction Worker.
# - IAM task role for SQS/AMP/DynamoDB/SNS/Secrets/SSM.
# - CloudWatch log group /ecs/prediction-worker.
# - ECS service runs in private subnets with no public IP.
# - Service Connect client config to call AI by http://ai-engine:8080.
# - CDO-W12-025: sign Worker -> AI request with SigV4-style Authorization.
# -----------------------------------------------------------------------------

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

      # Sandbox probe for CDO-W12-025.
      # It signs a POST /v1/predict request with ECS task credentials.
      # On HTTP 401, it refreshes credentials, re-signs, and retries once only.
      command = [
        "python",
        "-c",
        <<-PY
import datetime
import hashlib
import hmac
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))

REGION = os.environ.get("AWS_REGION", "us-east-1")
SERVICE = os.environ.get("AI_SIGV4_SERVICE", "ai-engine")
AI_BASE_URL = os.environ.get("AI_ENGINE_BASE_URL", "http://ai-engine:8080")
AI_PREDICT_PATH = os.environ.get("AI_PREDICT_PATH", "/v1/predict")
WORKER_PRINCIPAL_ARN = os.environ.get("WORKER_PRINCIPAL_ARN", "")

def get_task_credentials():
    rel_uri = os.environ.get("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
    full_uri = os.environ.get("AWS_CONTAINER_CREDENTIALS_FULL_URI")

    if rel_uri:
        url = "http://169.254.170.2" + rel_uri
    elif full_uri:
        url = full_uri
    else:
        raise RuntimeError("No ECS task credentials endpoint found")

    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read().decode())

def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

def get_signature_key(secret_key, date_stamp, region_name, service_name):
    k_date = sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    k_region = hmac.new(k_date, region_name.encode("utf-8"), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service_name.encode("utf-8"), hashlib.sha256).digest()
    k_signing = hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()
    return k_signing

def build_signed_headers(creds, method, url, payload):
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc
    canonical_uri = parsed.path or "/"
    canonical_querystring = ""

    now = datetime.datetime.utcnow()
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")

    payload_hash = hashlib.sha256(payload.encode("utf-8")).hexdigest()

    headers = {
        "content-type": "application/json",
        "host": host,
        "x-amz-date": amz_date,
        "x-amz-security-token": creds["Token"],
        "x-worker-principal": WORKER_PRINCIPAL_ARN
    }

    signed_headers = "content-type;host;x-amz-date;x-amz-security-token;x-worker-principal"

    canonical_headers = (
        "content-type:" + headers["content-type"] + "\\n" +
        "host:" + headers["host"] + "\\n" +
        "x-amz-date:" + headers["x-amz-date"] + "\\n" +
        "x-amz-security-token:" + headers["x-amz-security-token"] + "\\n" +
        "x-worker-principal:" + headers["x-worker-principal"] + "\\n"
    )

    canonical_request = (
        method + "\\n" +
        canonical_uri + "\\n" +
        canonical_querystring + "\\n" +
        canonical_headers + "\\n" +
        signed_headers + "\\n" +
        payload_hash
    )

    algorithm = "AWS4-HMAC-SHA256"
    credential_scope = date_stamp + "/" + REGION + "/" + SERVICE + "/aws4_request"

    string_to_sign = (
        algorithm + "\\n" +
        amz_date + "\\n" +
        credential_scope + "\\n" +
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()
    )

    signing_key = get_signature_key(creds["SecretAccessKey"], date_stamp, REGION, SERVICE)
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    authorization_header = (
        algorithm + " " +
        "Credential=" + creds["AccessKeyId"] + "/" + credential_scope + ", " +
        "SignedHeaders=" + signed_headers + ", " +
        "Signature=" + signature
    )

    headers["Authorization"] = authorization_header
    return headers

def call_ai_predict(retry_once=True):
    url = AI_BASE_URL + AI_PREDICT_PATH

    payload = json.dumps({
        "tenant_id": "demo-tenant-001",
        "service_id": "payment-gateway",
        "lookback_window_minutes": 120,
        "prediction_mode": "balanced",
        "correlation_id": "sigv4-demo"
    })

    attempts = 0
    max_attempts = 2 if retry_once else 1

    while attempts < max_attempts:
        attempts += 1

        creds = get_task_credentials()
        headers = build_signed_headers(creds, "POST", url, payload)

        print("calling AI with SigV4 attempt=" + str(attempts), flush=True)
        print("signed url=" + url, flush=True)
        print("authorization header prefix=" + headers["Authorization"][:32], flush=True)
        print("worker principal=" + WORKER_PRINCIPAL_ARN, flush=True)

        req = urllib.request.Request(
            url,
            data=payload.encode("utf-8"),
            headers=headers,
            method="POST"
        )

        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                body = r.read().decode()
                print("ai predict status=" + str(r.status), flush=True)
                print("ai predict body=" + body, flush=True)
                return True

        except urllib.error.HTTPError as e:
            body = e.read().decode()
            print("ai predict http error status=" + str(e.code), flush=True)
            print("ai predict error body=" + body, flush=True)

            if e.code == 401 and attempts < max_attempts:
                print("received 401, refreshing task credentials and retrying once", flush=True)
                continue

            if e.code == 401:
                print("invalid SigV4 after retry once; stopping without infinite retry", flush=True)

            return False

        except Exception as e:
            print("ai predict unexpected error=" + str(e), flush=True)
            return False

    return False

print("prediction-worker SigV4 demo starting", flush=True)

ok = call_ai_predict(retry_once=True)

print("sigv4_demo_result=" + str(ok), flush=True)

time.sleep(10**9)
PY
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
          name  = "AI_SIGV4_SERVICE"
          value = "ai-engine"
        },
        {
          name  = "WORKER_PRINCIPAL_ARN"
          value = aws_iam_role.prediction_worker_task_role.arn
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