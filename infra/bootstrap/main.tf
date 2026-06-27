# -----------------------------------------------------------------------------
# CDO-04 Terraform Bootstrap
#
# Creates the foundational state backend and CI/CD resources:
#   - S3 bucket for Terraform remote state (versioned, encrypted, blocked public access)
#   - GitHub OIDC provider and Terraform deploy role for CI/CD
#
# State locking uses Terraform >= 1.10 native S3 lockfile (use_lockfile = true).
# DynamoDB lock table is NOT created (deprecated per AWS/Terraform guidance).
#
# Apply once per AWS account. Main Terraform root references this
# state bucket in its backend configuration.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# AWS PROVIDER
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

# -----------------------------------------------------------------------------
# RANDOM SUFFIX
# -----------------------------------------------------------------------------
# S3 bucket names are globally unique. A random suffix avoids collisions
# without requiring a user-provided override.
resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# -----------------------------------------------------------------------------
# S3 STATE BUCKET
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.state_bucket_name_prefix}-${random_string.bucket_suffix.result}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: move noncurrent state versions to cheaper storage after 30 days,
# then expire after 180 days. Current versions are unaffected (versioning is on).
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "noncurrent-version-cleanup"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 180
    }
  }
}

# TLS-only bucket policy: deny any request without aws:SecureTransport
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonTLS"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# GITHUB OIDC PROVIDER
# -----------------------------------------------------------------------------
# Allows GitHub Actions to assume an IAM role without long-lived credentials.
# The provider is created once per account and reused across environments.
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    # GitHub Actions OIDC thumbprint (stable, per AWS docs)
    "6938fd4d98bab03faadb97b34396831e3780aea1",
  ]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# TERRAFORM DEPLOY ROLE
# -----------------------------------------------------------------------------
# This role is assumed by GitHub Actions to run terraform plan/apply.
# Trust policy limits access to the configured GitHub org/repo/branch.
#
# Least-privilege trust:
#   - sub = repo:org/repo:ref:refs/heads/<branch> (exact branch if set, else *)
#   - Explicit audience condition (aud = sts.amazonaws.com)
#   - Uses StringEquals for aud, StringLike for sub (branch wildcard support)
resource "aws_iam_role" "terraform_deploy" {
  name = "${var.project_name}-${var.environment}-terraform-deploy"
  path = "/github-actions/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Require audience sts.amazonaws.com (critical OIDC security control)
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to exact repo; branch uses variable (default "*" = all branches)
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
          }
        }
      }
    ]
  })

  tags = var.tags
}

# -----------------------------------------------------------------------------
# TERRAFORM DEPLOY ROLE POLICY (least-privilege bootstrap)
# -----------------------------------------------------------------------------
# This policy grants only the permissions needed for Terraform to manage
# the state backend during CI/CD plan/apply. It does NOT include broad
# resource discovery (Describe*/List*) -- those belong in a separate,
# environment-scoped deploy role created by the main Terraform root.
#
# Permissions:
#   - S3 state bucket: GetObject, PutObject, DeleteObject, ListBucket
#     (Get/Put/List for plan, Delete for lockfile cleanup)
resource "aws_iam_role_policy" "terraform_deploy_backend" {
  name = "${var.project_name}-${var.environment}-terraform-deploy-backend"
  role = aws_iam_role.terraform_deploy.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 state bucket read/write/list (including lockfile)
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*",
        ]
      },
      # Allow Terraform to check caller identity (needed for assume-role + AWS provider)
      {
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      },
    ]
  })
}
