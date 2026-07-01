# -----------------------------------------------------------------------------
# GitHub Actions Terraform Deploy Policy
#
# Bounded policy for W12 Terraform plan/apply.
# Not AdministratorAccess.
# Guardrails:
# - Project tag: Project=tf4-cdo04
# - IAM role/policy prefix: tf4-cdo04-*
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "github_deploy_policy" {
  statement {
    sid    = "AllowTerraformReadOnlyDiscovery"
    effect = "Allow"

    actions = [
      "sts:GetCallerIdentity",

      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "ecs:Describe*",
      "ecs:List*",
      "iam:Get*",
      "iam:List*",
      "logs:Describe*",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "sqs:Get*",
      "sqs:List*",
      "sns:Get*",
      "sns:List*",
      "dynamodb:Describe*",
      "dynamodb:List*",
      "s3:Get*",
      "s3:List*",
      "kms:Describe*",
      "kms:List*",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
      "aps:Describe*",
      "aps:List*",
      "scheduler:Get*",
      "scheduler:List*",
      "application-autoscaling:Describe*",
      "ecr:Describe*",
      "ecr:Get*",
      "apigateway:GET"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowCreateWithProjectTag"
    effect = "Allow"

    actions = [
      "ec2:CreateVpc",
      "ec2:CreateSubnet",
      "ec2:CreateRouteTable",
      "ec2:CreateRoute",
      "ec2:CreateInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:AllocateAddress",
      "ec2:ReleaseAddress",
      "ec2:CreateNatGateway",
      "ec2:CreateTags",
      "ec2:CreateSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:CreateVpcEndpoint",

      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:AddTags",

      "ecs:CreateCluster",
      "ecs:CreateService",
      "ecs:RegisterTaskDefinition",
      "ecs:TagResource",

      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:TagResource",
      "logs:PutRetentionPolicy",

      "sqs:CreateQueue",
      "sqs:TagQueue",
      "sqs:SetQueueAttributes",

      "sns:CreateTopic",
      "sns:TagResource",

      "dynamodb:CreateTable",
      "dynamodb:TagResource",

      "s3:CreateBucket",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutBucketEncryption",
      "s3:PutBucketPolicy",
      "s3:PutLifecycleConfiguration",
      "s3:PutPublicAccessBlock",

      "kms:CreateKey",
      "kms:TagResource",

      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",

      "aps:CreateWorkspace",
      "aps:TagResource",

      "scheduler:CreateSchedule",
      "scheduler:TagResource",

      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:PutScalingPolicy",

      "ecr:CreateRepository",
      "ecr:TagResource",
      "ecr:PutLifecyclePolicy"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid    = "AllowManageTaggedProjectResources"
    effect = "Allow"

    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "ecs:*",
      "logs:*",
      "cloudwatch:*",
      "sqs:*",
      "sns:*",
      "dynamodb:*",
      "s3:*",
      "kms:*",
      "secretsmanager:*",
      "aps:*",
      "scheduler:*",
      "application-autoscaling:*",
      "ecr:*"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid    = "AllowManageProjectIAMOnly"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy"
    ]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-*"
    ]
  }

  statement {
    sid    = "AllowPassProjectRolesToAWSService"
    effect = "Allow"

    actions = ["iam:PassRole"]

    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*"
    ]

    condition {
      test     = "StringLike"
      variable = "iam:PassedToService"
      values = [
        "ecs-tasks.amazonaws.com",
        "ecs.amazonaws.com",
        "scheduler.amazonaws.com",
        "lambda.amazonaws.com"
      ]
    }
  }

  statement {
    sid    = "AllowProjectS3Access"
    effect = "Allow"

    actions = [
      "s3:*"
    ]

    resources = [
      "arn:aws:s3:::tf4-cdo04-*",
      "arn:aws:s3:::tf4-cdo04-*/*"
    ]
  }

  statement {
    sid    = "AllowECRPushAccess"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage"
    ]

    resources = [
      "arn:aws:ecr:*:*:repository/foresight-lens/*"
    ]
  }

  statement {
    sid    = "AllowUntaggedServicesAccess"
    effect = "Allow"

    actions = [
      "ssm:*",
      "servicediscovery:*",
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:TagResource",
      "apigateway:UntagResource",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "ecs:DeregisterTaskDefinition",
      "cloudwatch:*",
      "sns:*",
      "application-autoscaling:*",
      "scheduler:*"
    ]

    resources = [
      "arn:aws:ssm:*:*:parameter/tf4-cdo04/*",
      "*"
    ]
  }

  statement {
    sid    = "AllowManageProjectLambda"
    effect = "Allow"

    actions = [
      # Read: dùng wildcard Get*/List* để cover toàn bộ sub-API mà Terraform
      # gọi khi refresh aws_lambda_function (GetFunction, GetPolicy,
      # GetFunctionCodeSigningConfig, ListVersionsByFunction, ListTags, ...)
      "lambda:Get*",
      "lambda:List*",
      # Write: liệt kê cụ thể từng action cần thiết
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:DeleteFunction",
      "lambda:PutFunctionEventInvokeConfig",
      "lambda:DeleteFunctionEventInvokeConfig",
      "lambda:AddPermission",
      "lambda:RemovePermission"
    ]

    resources = [
      "arn:aws:lambda:*:*:function:tf4-cdo04-cost-breaker-*"
    ]
  }

  statement {
    sid    = "AllowManageProjectBudgets"
    effect = "Allow"

    # AWS Budgets không hỗ trợ resource-level ARN restriction (AWS limitation).
    # Bắt buộc dùng resources = ["*"], nhưng đã thu hẹp bằng:
    # 1. Chỉ liệt kê đúng các action Terraform cần (không dùng budgets:*)
    # 2. Condition giới hạn theo Account ID của project
    actions = [
      "budgets:CreateBudget",
      "budgets:ModifyBudget",
      "budgets:DeleteBudget",
      "budgets:ViewBudget",
      "budgets:DescribeBudget",
      "budgets:DescribeBudgets",
      "budgets:DescribeBudgetActionsForBudget",
      "budgets:TagResource",
      "budgets:UntagResource"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # budgets:ListTagsForResource Hỗ TRỢ resource-level ARN (khác với các action trên)
  # Có thể scope chính xác vào ARN của budget dự án
  statement {
    sid    = "AllowBudgetTagRead"
    effect = "Allow"

    actions = ["budgets:ListTagsForResource"]

    resources = [
      "arn:aws:budgets::${data.aws_caller_identity.current.account_id}:budget/tf4-cdo04-*"
    ]
  }

  statement {
    sid    = "AllowManageProjectACM"
    effect = "Allow"

    actions = [
      "acm:RequestCertificate",
      "acm:DescribeCertificate",
      "acm:DeleteCertificate",
      "acm:GetCertificate",
      "acm:ListCertificates",
      "acm:AddTagsToCertificate",
      "acm:RemoveTagsFromCertificate",
      "acm:ListTagsForCertificate"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_deploy_policy" {
  name        = "${var.project_name}-github-deploy-policy"
  description = "Bounded Terraform deploy policy for ${var.project_name} GitHub Actions"
  policy      = data.aws_iam_policy_document.github_deploy_policy.json

  tags = merge(var.tags, {
    Name    = "${var.project_name}-github-deploy-policy"
    Purpose = "terraform-deploy"
  })
}

resource "aws_iam_role_policy_attachment" "attach_github_deploy_policy" {
  role       = aws_iam_role.github_deploy_role.name
  policy_arn = aws_iam_policy.github_deploy_policy.arn
}