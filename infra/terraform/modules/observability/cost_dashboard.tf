# -----------------------------------------------------------------------------
# TASK: CPOA-100 | CDO-W12-055 - Cost Dashboard and Billing Metric Alarm
# OWNER: Tạ Hoàng Huy
#
# DESCRIPTION:
# File này định nghĩa các tài nguyên CloudWatch để giám sát chi phí ước tính (Estimated Charges).
# Bao gồm:
# 1. CloudWatch Metric Alarm giám sát chi phí tại vùng us-east-1 (được ép qua provider alias).
# 2. CloudWatch Dashboard trực quan hóa Estimated Charges cùng các hướng dẫn đối soát cho SRE.
# -----------------------------------------------------------------------------

# =============================================================================
# 1. CẤU HÌNH PROVIDER PHỤ DÀNH RIÊNG CHO US-EAST-1
# =============================================================================
# Vì metric EstimatedCharges (Billing) của AWS chỉ được lưu trữ và xuất ra tại vùng
# N. Virginia (us-east-1), chúng ta bắt buộc phải dùng provider alias us_east_1 
# để khởi tạo Alarm tại vùng này, tránh lỗi sập biên dịch của Terraform.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# =============================================================================
# 2. CLOUDWATCH METRIC ALARM GIÁM SÁT CHI PHÍ
# =============================================================================
# Cảnh báo này sẽ giám sát EstimatedCharges từ namespace AWS/Billing.
# - Ngưỡng cảnh báo: $160 (tương ứng 80% ngân sách trần $200/tháng).
# - Chu kỳ đánh giá: 6 giờ (21600 giây) do metric Billing của AWS chỉ cập nhật 4 lần/ngày.
# - Action: Gửi thông báo trực tiếp tới SNS Topic chung budget_alert.
resource "aws_cloudwatch_metric_alarm" "billing_alarm" {
  provider            = aws.us_east_1
  alarm_name          = "${var.project_name}-billing-alarm-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = "21600" # 6 giờ (tần suất cập nhật metric billing của AWS)
  statistic           = "Maximum"
  threshold           = "160" # Ngưỡng cảnh báo sớm 80% ($160 trên ngân sách $200)
  alarm_description   = "Cảnh báo khi chi phí ước tính vượt quá 80% ngân sách ($160)"

  # Tham chiếu trực tiếp tới SNS topic trong cùng module để tối ưu hóa và tránh phụ thuộc vòng lặp
  alarm_actions = [aws_sns_topic.budget_alert.arn]

  dimensions = {
    Currency = "USD"
  }
}

# =============================================================================
# 3. CLOUDWATCH COST DASHBOARD (DASHBOARD QUẢN LÝ CHI PHÍ)
# =============================================================================
# Dashboard được tạo ở vùng mặc định của dự án nhưng truy vấn metric EstimatedCharges 
# từ us-east-1. Dashboard có cấu trúc grid gồm 2 widget:
# - Widget 1 (Metric): Biểu đồ time-series thể hiện chi phí lũy kế EstimatedCharges.
# - Widget 2 (Text): Hướng dẫn đối soát hóa đơn cho SRE kèm link trực tiếp Cost Explorer.
resource "aws_cloudwatch_dashboard" "cost_dashboard" {
  dashboard_name = "${var.project_name}-cost-dashboard-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      # Widget 1: Biểu đồ giám sát chi phí
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/Billing", "EstimatedCharges", "Currency", "USD", { "stat": "Maximum" }]
          ]
          period  = 86400
          region  = "us-east-1"
          title   = "Estimated Charges (USD)"
          view    = "timeSeries"
          stacked = false
        }
      },
      # Widget 2: Cẩm nang hướng dẫn đối soát chi phí cho SRE
      {
        type   = "text"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          markdown = <<EOT
###  CDO-04 Cost Reconciliation & Audit Guide

####  Quick Links
* **[AWS Cost Explorer (Filtered by Project)](https://console.aws.amazon.com/costmanagement/home#/custom?groupBy=Service&timeFrame=DAILY&type=chart&filter=%5B%7B%22dimension%22%3A%22TagKeyValue%22%2C%22values%22%3A%5B%22Project%24tf4-cdo04%22%5D%7D%5D)**

####  Hướng dẫn đối soát hóa đơn
1.  **Theo dõi hạn mức ngày**: Đảm bảo chi phí trung bình hàng ngày dưới **$6.66/ngày** để duy trì trong hạn mức $200/tháng.
2.  **Xác thực thẻ tài nguyên (Tagging)**: Đảm bảo mọi tài nguyên được tạo có tag `Project = tf4-cdo04` and `Environment = ${var.environment}`.
3.  **Kiểm tra dịch vụ ECS**: Nếu chi phí tăng đột biến, kiểm tra số lượng task hoạt động của `telemetry-api` (tối đa 2) và xem `ai-engine` / `prediction-worker` đã được scale về 0 hay chưa (nếu circuit breaker đã kích hoạt).
4.  **Kiểm tra NAT Gateway**: Theo dõi dung lượng xử lý dữ liệu của NAT Gateway để tránh chạy load test quá công suất ngoài khung giờ quy định.
5.  **Chu kỳ đối soát**: Thực hiện đối soát định kỳ hàng tuần dung lượng Timestream Ingest và lượng message ném vào DLQ của SQS.
EOT
        }
      }
    ]
  })
}
