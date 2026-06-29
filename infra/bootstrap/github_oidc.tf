# -----------------------------------------------------------------------------
# GitHub Actions OIDC Deploy Role
#
# An-owned scope (CPOA-38 / CDO-W12-002):
# - IAM OIDC Provider for token.actions.githubusercontent.com
# - IAM deploy role for GitHub Actions
# - Trust policy scoped to official repo/branches/environments
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  github_oidc_allowed_subjects = concat(
    [
      "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",
      "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/develop",
      "repo:${var.github_owner}/${var.github_repo}:pull_request",
      "repo:${var.github_owner}/${var.github_repo}:environment:staging",
      "repo:${var.github_owner}/${var.github_repo}:environment:prod"
    ],
    [
      for branch in var.github_allowed_feature_branches :
      "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${branch}"
    ]
  )
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # GitHub Actions OIDC thumbprint commonly used for AWS IAM OIDC provider.
  # If AWS/provider retrieves a different current thumbprint, update this value.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]

  tags = merge(var.tags, {
    Name    = "${var.project_name}-github-oidc-provider"
    Purpose = "github-actions-oidc"
  })
}

data "aws_iam_policy_document" "github_oidc_trust" {
  statement {
    sid     = "AllowGitHubActionsAssumeRoleWithOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_oidc_allowed_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy_role" {
  name               = "${var.project_name}-github-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust.json
  description        = "GitHub Actions OIDC deploy role for ${var.project_name} Terraform plan/apply"

  tags = merge(var.tags, {
    Name    = "${var.project_name}-github-deploy-role"
    Purpose = "terraform-deploy"
  })
}