# -----------------------------------------------------------------------------
# CDO-04 Automation Script: Create IAM Groups and Users
#
# Tech Lead runs this locally using AWS CLI configure profile.
# -----------------------------------------------------------------------------

# Tat tinh nang tu dong phan trang (pager) cua AWS CLI de tranh bi treo script
$env:AWS_PAGER=""


Write-Host "=== KHOI TAO CAC IAM GROUPS ===" -ForegroundColor Green
aws iam create-group --group-name cdo04-infra-group
aws iam create-group --group-name cdo04-app-group
aws iam create-group --group-name cdo04-obs-group
aws iam create-group --group-name cdo04-finops-group

Write-Host "=== GAN CAC MANAGED POLICIES CHO IAM GROUPS ===" -ForegroundColor Green

# 1. Group Infra: AdministratorAccess (Full quyen Admin de Vinh & An deploy IaC khong bi block)
aws iam attach-group-policy --group-name cdo04-infra-group --policy-arn arn:aws:iam::aws:policy/AdministratorAccess





# 2. Group App: ECR PowerUser & ECS Full Access (Day code & deploy)
aws iam attach-group-policy --group-name cdo04-app-group --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam attach-group-policy --group-name cdo04-app-group --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess

# 3. Group Obs: CloudWatch Full Access & AMP Query (Giam sat & test)
aws iam attach-group-policy --group-name cdo04-obs-group --policy-arn arn:aws:iam::aws:policy/CloudWatchFullAccess
aws iam attach-group-policy --group-name cdo04-obs-group --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess

# 4. Group FinOps: Budgets Access & S3 Full Access (Kiem soat chi phi & retention)
aws iam attach-group-policy --group-name cdo04-finops-group --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Tao policy Budgets admin vi AWS khong co policy managed san cho budget write
Write-Host "Tao va gan policy budgets cho finops..."
aws iam create-policy --policy-name cdo04-budgets-full-access --policy-document file://note/budgets-policy.json 2>$null
$accountId = "511825856493"
aws iam attach-group-policy --group-name cdo04-finops-group --policy-arn "arn:aws:iam::${accountId}:policy/cdo04-budgets-full-access"





Write-Host "=== KHOI TAO IAM USERS, SET PASSWORD & GAN VAO GROUP ===" -ForegroundColor Green

function Create-User-Helper($username, $password, $groupName) {
    Write-Host "Dang tao User: $username..." -ForegroundColor Cyan
    aws iam create-user --user-name $username
    
    # Tao mat khau va KHONG bat buoc doi o lan dau dang nhap (theo yeu cau cua Tech Lead)
    aws iam create-login-profile --user-name $username --password $password --no-password-reset-required
    
    # Gan user vao group tuong ung
    aws iam add-user-to-group --user-name $username --group-name $groupName
}

Create-User-Helper "cdo04-vinh" "Cdo04-vinh-@2026" "cdo04-infra-group"
Create-User-Helper "cdo04-an" "Cdo04-an-@2026" "cdo04-infra-group"
Create-User-Helper "cdo04-tin" "Cdo04-tin-@2026" "cdo04-app-group"
Create-User-Helper "cdo04-tuan" "Cdo04-tuan-@2026" "cdo04-app-group"
Create-User-Helper "cdo04-ninh" "Cdo04-ninh-@2026" "cdo04-obs-group"
Create-User-Helper "cdo04-huy" "Cdo04-huy-@2026" "cdo04-finops-group"

Write-Host "=== DA KHOI TAO XONG TOAN BO USER & GROUP! ===" -ForegroundColor Green
