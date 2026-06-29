# Bootstrap -- CDO-04 Terraform Foundation

Bootstrap scope:
- CPOA-37: Terraform S3 backend bucket
- CPOA-38 / CDO-W12-002: GitHub Actions OIDC provider and Terraform deploy role

Creates:
- S3 state bucket
- Versioning
- AES256 encryption
- Block Public Access
- TLS-only bucket policy
- Noncurrent-version lifecycle
- Native Terraform S3 lockfile workflow (`use_lockfile = true`)
- IAM OIDC Provider for `token.actions.githubusercontent.com`
- IAM Role `tf4-cdo04-github-deploy-role`
- Bounded Terraform deploy policy with `Project=tf4-cdo04` tag guardrail

Does not create:
- DynamoDB lock table
- Static AWS access keys for GitHub Actions
- AdministratorAccess policy
## GitHub OIDC deploy role

GitHub Actions assumes `tf4-cdo04-github-deploy-role` through OIDC.

Allowed trust subjects:
- `repo:dragongoldi2609/tf4-cdo04-repo:ref:refs/heads/main`
- `repo:dragongoldi2609/tf4-cdo04-repo:ref:refs/heads/develop`
- `repo:dragongoldi2609/tf4-cdo04-repo:environment:staging`
- `repo:dragongoldi2609/tf4-cdo04-repo:environment:prod`
- temporary feature branches listed in `github_allowed_feature_branches`

GitHub workflow must use:

```yaml
permissions:
  id-token: write
  contents: read

---

# 7. Tạo workflow smoke test

Tạo folder/file:

```powershell
mkdir .github\workflows
New-Item .github\workflows\oidc-smoke-test.yml

Dán:

name: OIDC Smoke Test

on:
  workflow_dispatch:
  push:
    branches:
      - main
      - develop
      - An_CDO-W12-002-github-oidc

permissions:
  id-token: write
  contents: read

jobs:
  assume-role-test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials by OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: us-east-1
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/tf4-cdo04-github-deploy-role
          role-session-name: github-actions-tf4-cdo04

      - name: Verify caller identity
        run: |
          aws sts get-caller-identity

Lấy <ACCOUNT_ID> bằng:

aws sts get-caller-identity

GitHub OIDC không cần lưu AWS access key dài hạn trong GitHub Secrets; workflow dùng OIDC token để assume role tạm thời.