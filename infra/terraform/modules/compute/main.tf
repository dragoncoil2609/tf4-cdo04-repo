# -----------------------------------------------------------------------------
# CDO-04 Compute Module -- Main Resources
#
# Vinh-owned scope kept here:
#   - CPOA-41: ECS Cluster + Service Connect namespace
#   - CPOA-78: ECR repos and lifecycle policies
# -----------------------------------------------------------------------------
#
# Service-specific resources live in sibling files:
#   - CPOA-45/CPOA-46: Telemetry API task and service (telemetry_api.tf)
#   - CPOA-47: Prediction Worker task definition (prediction_worker.tf)
#   - CPOA-48: AI Engine task definition (ai_engine.tf)
#   - CPOA-49: Service Connect AI route (ai_engine.tf)
#   - CPOA-50: ECS autoscaling policies (autoscaling.tf)
#   - CPOA-51: AI baseline S3 access (ai_engine.tf)
# -----------------------------------------------------------------------------

locals {
  cluster_name              = "${var.project_name}-${var.environment}-cluster"
  service_connect_namespace = "${var.project_name}-${var.environment}.local"
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
# TASK: CPOA-103 | CDO-W12-058 - Retention policies
# OWNER: Tạ Hoàng Huy
#
# DESCRIPTION:
# Cấu hình chính sách vòng đời ECR:
# 1. Ưu tiên 1 (Priority 1): Dọn sạch ảnh không tag (untagged) cũ hơn 14 ngày.
# 2. Ưu tiên 2 (Priority 2): Giữ lại tối đa 10 ảnh gần nhất của bất kỳ tag nào để an toàn cho staging/prod.
# -----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "services" {
  for_each = aws_ecr_repository.services

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Xoa cac anh untagged cu hon 14 ngay truoc de giai phong bo nho"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Sau do, gioi han chi giu toi đa 10 anh co tag gan nhat de an toan cho Production"
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
# ECR repos, deploy wiring, ALB/service rollout, and smoke deployment (CPOA-78)
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "services" {
  for_each             = toset(["telemetry_api", "prediction_worker", "ai_engine"])
  name                 = "foresight-lens/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${each.key}-ecr"
    Purpose = "ecr-repository"
  })
}

