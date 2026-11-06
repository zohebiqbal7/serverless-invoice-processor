<#
.SYNOPSIS
    Removes all resources created by deploy.ps1 for serverless-invoice-processor.

.DESCRIPTION
    Deletes (in safe order): S3 trigger + buckets (emptied first), Lambda function,
    IAM role + policies, DynamoDB table. Pulls account ID at runtime.
    Only touches resources matching the configured names - nothing else in your account.

.EXAMPLE
    ./teardown.ps1
    ./teardown.ps1 -BucketSuffix mydemo -Force
#>
param(
    [string]$Region       = "us-east-1",
    [string]$FunctionName = "invoice-processor",
    [string]$TableName    = "invoices",
    [string]$RoleName     = "invoice-processor-role",
    [string]$BucketSuffix = "",
    [switch]$Force   # skip the confirmation prompt
)

$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot
$ProjectRoot = Split-Path -Parent $PSScriptRoot  # repo root (one level up from deploy/)

$AccountId = (aws sts get-caller-identity --query Account --output text).Trim()
if (-not $AccountId) { throw "Could not resolve AWS account. Are your credentials configured?" }
if (-not $BucketSuffix) { $BucketSuffix = $AccountId }

$SourceBucket = "invoice-source-$BucketSuffix"
$OutputBucket = "textract-ml-ai-$BucketSuffix"

Write-Host "This will DELETE the following in account $AccountId ($Region):" -ForegroundColor Yellow
Write-Host "  - Lambda function : $FunctionName"
Write-Host "  - S3 buckets      : $SourceBucket, $OutputBucket (and all contents)"
Write-Host "  - IAM role        : $RoleName"
Write-Host "  - DynamoDB table  : $TableName"
if (-not $Force) {
    $confirm = Read-Host "`nType 'yes' to proceed"
    if ($confirm -ne "yes") { Write-Host "Aborted."; return }
}

Write-Host "`n==> Deleting Lambda function..." -ForegroundColor Cyan
aws lambda delete-function --function-name $FunctionName --region $Region 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host "    Deleted." -ForegroundColor Green } else { Write-Host "    Not found, skipping." -ForegroundColor Yellow }

Write-Host "`n==> Emptying + deleting S3 buckets..." -ForegroundColor Cyan
foreach ($b in @($SourceBucket, $OutputBucket)) {
    aws s3api head-bucket --bucket $b 2>$null
    if ($LASTEXITCODE -eq 0) {
        aws s3 rb "s3://$b" --force --region $Region 2>$null
        Write-Host "    Removed $b" -ForegroundColor Green
    } else { Write-Host "    $b not found, skipping." -ForegroundColor Yellow }
}

Write-Host "`n==> Deleting IAM role..." -ForegroundColor Cyan
aws iam get-role --role-name $RoleName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    # Detach managed policies
    $attached = aws iam list-attached-role-policies --role-name $RoleName --query "AttachedPolicies[].PolicyArn" --output text 2>$null
    if ($attached) { foreach ($arn in ($attached -split "\s+")) { if ($arn) { aws iam detach-role-policy --role-name $RoleName --policy-arn $arn 2>$null } } }
    # Delete inline policies
    $inline = aws iam list-role-policies --role-name $RoleName --query "PolicyNames[]" --output text 2>$null
    if ($inline) { foreach ($p in ($inline -split "\s+")) { if ($p) { aws iam delete-role-policy --role-name $RoleName --policy-name $p 2>$null } } }
    aws iam delete-role --role-name $RoleName 2>$null
    Write-Host "    Deleted." -ForegroundColor Green
} else { Write-Host "    Not found, skipping." -ForegroundColor Yellow }

Write-Host "`n==> Deleting DynamoDB table..." -ForegroundColor Cyan
aws dynamodb delete-table --table-name $TableName --region $Region 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "    Delete requested." -ForegroundColor Green } else { Write-Host "    Not found, skipping." -ForegroundColor Yellow }

# Clean local build artifact
Remove-Item (Join-Path $ProjectRoot "function.zip") -ErrorAction SilentlyContinue

Write-Host "`n==================================================" -ForegroundColor Green
Write-Host " Teardown complete." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green