# -----------------------------------------------------------------------------
# CDO-04 Observability Module -- Additional Variables (CPOA-88)
# Dùng riêng cho CloudWatch Dashboard & Alarms
# -----------------------------------------------------------------------------

variable "alb_arn_suffix" {
  description = "ARN suffix của ALB (phần sau 'loadbalancer/'). Dùng để filter metric đúng ALB khi có nhiều ALB trong cùng account."
  type        = string
  # Cách truyền giá trị: lấy từ thuộc tính `arn_suffix` của resource aws_lb
}

variable "runbook_url" {
  description = "URL tới runbook nội bộ, đính kèm trong alarm_description để on-call dễ tra cứu"
  type        = string
  default     = "https://wiki.internal/runbooks/observability"
}