# -----------------------------------------------------------------------------
# TASK: CPOA-103 | CDO-W12-058 - Retention policies
# OWNER: Tạ Hoàng Huy
#
# DESCRIPTION:
# Cấu hình Log Group lưu trữ audit logs của AI Engine:
# 1. retention_in_days = 365 (lưu giữ 1 năm cho mục đích audit bảo mật).
# 2. Cấu hình mã hóa KMS (kms_key_id) để đảm bảo an toàn dữ liệu logs at rest.
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ai_engine_audit" {
  name              = "/ecs/${var.project_name}-${var.environment}-ai-engine-audit"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name    = "${var.project_name}-${var.environment}-ai-engine-audit-logs"
    Purpose = "ai-engine-audit-logs"
  })
}
