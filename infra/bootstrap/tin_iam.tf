# -----------------------------------------------------------------------------
# CDO-04 Developer Permissions for Tín (Q9)
#
# Constraints:
# - CloudWatch Logs: CloudWatchLogsFullAccess
# - Amazon Prometheus (AMP): aps:* on resource * (only 1 workspace in account)
# - S3 Project Bucket: Read/write allowed for tf4-cdo04-evidence-* only.
# - S3 Terraform State Bucket: Explicitly Deny to prevent state tampering.
# -----------------------------------------------------------------------------

resource "aws_iam_user" "tin" {
  name = "tin"

  tags = merge(var.tags, {
    Name    = "tin"
    Purpose = "developer-access"
  })
}

# 1. Attach CloudWatchLogsFullAccess to Tin
resource "aws_iam_user_policy_attachment" "tin_cw_logs" {
  user       = aws_iam_user.tin.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# 2. Inline Policy for Amazon Prometheus (AMP) and Bounded S3 Permissions
data "aws_iam_policy_document" "tin_custom_policy" {
  # Amazon Prometheus (AMP): Toàn quyền trên aps
  statement {
    sid       = "AllowPrometheusAccess"
    effect    = "Allow"
    actions   = ["aps:*"]
    resources = ["*"]
  }

  # S3: Cho phép đọc/ghi vào đúng bucket evidence của dự án
  statement {
    sid    = "AllowProjectEvidenceBucketAccess"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectVersion"
    ]
    resources = [
      "arn:aws:s3:::tf4-cdo04-evidence-*",
      "arn:aws:s3:::tf4-cdo04-evidence-*/*"
    ]
  }

  # S3: Chặn hoàn toàn (Deny) truy cập vào bucket Terraform State của dự án
  statement {
    sid    = "DenyTerraformStateBucketAccess"
    effect = "Deny"
    actions = [
      "s3:*"
    ]
    resources = [
      "arn:aws:s3:::tf4-cdo04-terraform-state-*",
      "arn:aws:s3:::tf4-cdo04-terraform-state-*/*"
    ]
  }
}

resource "aws_iam_user_policy" "tin_inline_policy" {
  name   = "tin-custom-permissions"
  user   = aws_iam_user.tin.name
  policy = data.aws_iam_policy_document.tin_custom_policy.json
}
