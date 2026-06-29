# -----------------------------------------------------------------------------
# TASK: CPOA-102 | CDO-W12-057 - Service Connect proxy cost/headroom check
# OWNER: Tạ Hoàng Huy
#
# RATIONALE (LÝ DO THIẾT KẾ CODE):
// 1. Tự động suy luận tên service Telemetry API dựa trên cấu trúc đặt tên đồng bộ
//    (${var.project_name}-${var.environment}-telemetry-api). Điều này giúp cô lập
//    thay đổi trong module observability mà không cần sửa output/input ở compute module
//    của các thành viên khác, tránh xung đột code (code merge conflict).
// 2. Sử dụng namespace tiêu chuẩn "AWS/ECS" và hai metrics quan trọng:
//    "CPUUtilization" và "MemoryUtilization" để giám sát tài nguyên ở mức Task Fargate.
// 3. Ngưỡng cảnh báo đặt ở mức >= 85% trong 1 chu kỳ 60 giây (period = 60, evaluation_periods = 1).
//    Thời gian 1 phút giúp phát hiện ngay lập tức tình trạng quá tải hoặc rò rỉ bộ nhớ
//    (OOM risk) khi có spike traffic đột biến.
// 4. Liên kết với SNS Topic 'aws_sns_topic.budget_alert.arn' được tạo sẵn từ Task 100
//    trong file budgets.tf để cảnh báo tự động về cho SRE qua Email/SNS.
# -----------------------------------------------------------------------------

locals {
  telemetry_api_service_name = "${var.project_name}-${var.environment}-telemetry-api"
  worker_service_name        = var.worker_service_name
  ai_service_name            = var.ai_service_name
}

# =============================================================================
# 1. Telemetry API Alarms (Giám sát tải API hấp thụ telemetry)
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "telemetry_api_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-telemetry-api-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Telemetry API CPU utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.telemetry_api_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "telemetry_api_memory_high" {
  alarm_name          = "${var.project_name}-${var.environment}-telemetry-api-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Telemetry API Memory utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.telemetry_api_service_name
  }
}

# =============================================================================
# 2. Prediction Worker Alarms (Giám sát tải của worker chạy phân tích)
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "worker_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-worker-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Prediction Worker CPU utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.worker_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_memory_high" {
  alarm_name          = "${var.project_name}-${var.environment}-worker-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi Prediction Worker Memory utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.worker_service_name
  }
}

# =============================================================================
# 3. AI Engine Alarms (Giám sát tải của AI serving container)
# =============================================================================
resource "aws_cloudwatch_metric_alarm" "ai_cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-ai-cpu-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi AI Engine CPU utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.ai_service_name
  }
}

resource "aws_cloudwatch_metric_alarm" "ai_memory_high" {
  alarm_name          = "${var.project_name}-${var.environment}-ai-memory-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Cảnh báo khi AI Engine Memory utilization vượt quá 85% trong 1 phút do Tạ Hoàng Huy thiết lập."
  alarm_actions       = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = local.ai_service_name
  }
}
