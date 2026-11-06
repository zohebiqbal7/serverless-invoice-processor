<#
.SYNOPSIS
    Deploys the serverless-invoice-processor stack (DynamoDB, S3, IAM, Lambda, S3 trigger).

.DESCRIPTION
    Idempotent-ish deploy script. Pulls your AWS account ID at runtime (nothing hardcoded).
    Creates:
      - DynamoDB table (invoices)
      - Source + output S3 buckets
      - IAM execution role with least-privilege inline policy
      - Lambda function from lambda_function.py
      - S3 -> Lambda trigger on the source bucket

    NOTE: Amazon Textract (AnalyzeExpense) requires the AWS Paid plan. On the Free plan
    the stack deploys successfully but the OCR call returns SubscriptionRequiredException.

.EXAMPLE
    ./deploy.ps1
    ./deploy.ps1 -BucketSuffix mydemo -Region us-east-1
#>
param(
    [string]$Region         = "us-east-1",
    [string]$FunctionName   = "invoice-processor",
    [string]$TableName      = "invoices",
    [string]$RoleName       = "invoice-processor-role",
    # Suffix appended to bucket names for global uniqueness. Defaults to the account ID.
    [string]$BucketSuffix   = ""
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

Write-Host "==> Resolving AWS account..." -ForegroundColor Cyan
$AccountId = (aws sts get-caller-identity --query Account --output text).Trim()
if (-not $AccountId) { throw "Could not resolve AWS account. Are your credentials configured?" }
if (-not $BucketSuffix) { $BucketSuffix = $AccountId }

$SourceBucket = "invoice-source-$BucketSuffix"
$OutputBucket = "textract-ml-ai-$BucketSuffix"
Write-Host "    Account:       $AccountId"
Write-Host "    Region:        $Region"
Write-Host "    Source bucket: $SourceBucket"
Write-Host "    Output bucket: $OutputBucket"

# ---------------------------------------------------------------------------
Write-Host "`n==> [1/6] DynamoDB table '$TableName'..." -ForegroundColor Cyan
$tableExists = aws dynamodb describe-table --table-name $TableName --region $Region 2>$null
if ($LASTEXITCODE -ne 0) {
    aws dynamodb create-table --table-name $TableName `
        --attribute-definitions AttributeName=invoice_id,AttributeType=S `
        --key-schema AttributeName=invoice_id,KeyType=HASH `
        --billing-mode PAY_PER_REQUEST --region $Region | Out-Null
    Write-Host "    Creating... waiting for ACTIVE"
    aws dynamodb wait table-exists --table-name $TableName --region $Region
    Write-Host "    Created." -ForegroundColor Green
} else { Write-Host "    Already exists, skipping." -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
Write-Host "`n==> [2/6] S3 buckets..." -ForegroundColor Cyan
foreach ($b in @($SourceBucket, $OutputBucket)) {
    $exists = aws s3api head-bucket --bucket $b 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($Region -eq "us-east-1") {
            aws s3api create-bucket --bucket $b --region $Region | Out-Null
        } else {
            aws s3api create-bucket --bucket $b --region $Region `
                --create-bucket-configuration LocationConstraint=$Region | Out-Null
        }
        Write-Host "    Created $b" -ForegroundColor Green
    } else { Write-Host "    $b already exists, skipping." -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
Write-Host "`n==> [3/6] IAM role '$RoleName'..." -ForegroundColor Cyan
$trust = @{
    Version   = "2012-10-17"
    Statement = @(@{ Effect="Allow"; Principal=@{ Service="lambda.amazonaws.com" }; Action="sts:AssumeRole" })
} | ConvertTo-Json -Depth 10

$perms = @{
    Version   = "2012-10-17"
    Statement = @(
        @{ Effect="Allow"; Action=@("logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"); Resource="arn:aws:logs:${Region}:${AccountId}:*" },
        @{ Effect="Allow"; Action=@("s3:GetObject","s3:PutObject","s3:HeadBucket"); Resource=@(
            "arn:aws:s3:::$SourceBucket/*","arn:aws:s3:::$SourceBucket",
            "arn:aws:s3:::$OutputBucket/*","arn:aws:s3:::$OutputBucket") },
        @{ Effect="Allow"; Action="textract:AnalyzeExpense"; Resource="*" },
        @{ Effect="Allow"; Action="bedrock:InvokeModel"; Resource="arn:aws:bedrock:*::foundation-model/amazon.nova-micro-v1:0" },
        @{ Effect="Allow"; Action="dynamodb:PutItem"; Resource="arn:aws:dynamodb:${Region}:${AccountId}:table/$TableName" }
    )
} | ConvertTo-Json -Depth 10

$trustFile = Join-Path $env:TEMP "sip-trust.json"
$permFile  = Join-Path $env:TEMP "sip-perms.json"
[System.IO.File]::WriteAllText($trustFile, $trust, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($permFile,  $perms, (New-Object System.Text.UTF8Encoding($false)))

$roleExists = aws iam get-role --role-name $RoleName 2>$null
if ($LASTEXITCODE -ne 0) {
    aws iam create-role --role-name $RoleName --assume-role-policy-document file://$trustFile | Out-Null
    Write-Host "    Created role." -ForegroundColor Green
} else { Write-Host "    Role exists, updating policy." -ForegroundColor Yellow }
aws iam put-role-policy --role-name $RoleName --policy-name "${FunctionName}-permissions" --policy-document file://$permFile | Out-Null
$RoleArn = (aws iam get-role --role-name $RoleName --query "Role.Arn" --output text).Trim()
Write-Host "    Role ARN: $RoleArn"
Write-Host "    Waiting for IAM propagation (10s)..."
Start-Sleep -Seconds 10

# ---------------------------------------------------------------------------
Write-Host "`n==> [4/6] Packaging + deploying Lambda '$FunctionName'..." -ForegroundColor Cyan
$zip = Join-Path $PSScriptRoot "function.zip"
Compress-Archive -Path (Join-Path $PSScriptRoot "lambda_function.py") -DestinationPath $zip -Force
$fnExists = aws lambda get-function --function-name $FunctionName --region $Region 2>$null
if ($LASTEXITCODE -ne 0) {
    aws lambda create-function --function-name $FunctionName --runtime python3.12 `
        --handler lambda_function.lambda_handler --role $RoleArn `
        --zip-file fileb://$zip --timeout 120 --memory-size 256 --region $Region | Out-Null
    Write-Host "    Created function." -ForegroundColor Green
    aws lambda wait function-active --function-name $FunctionName --region $Region
} else {
    aws lambda update-function-code --function-name $FunctionName --zip-file fileb://$zip --region $Region | Out-Null
    Write-Host "    Updated function code." -ForegroundColor Yellow
    aws lambda wait function-updated --function-name $FunctionName --region $Region
}

# ---------------------------------------------------------------------------
Write-Host "`n==> [5/6] Setting environment variable..." -ForegroundColor Cyan
aws lambda update-function-configuration --function-name $FunctionName `
    --environment "Variables={TEXTRACT_OUTPUT_BUCKET=$OutputBucket}" --region $Region | Out-Null
aws lambda wait function-updated --function-name $FunctionName --region $Region
Write-Host "    TEXTRACT_OUTPUT_BUCKET=$OutputBucket" -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Host "`n==> [6/6] Wiring S3 trigger..." -ForegroundColor Cyan
# Allow S3 to invoke the function (ignore error if the statement already exists)
aws lambda add-permission --function-name $FunctionName --statement-id s3invoke `
    --action lambda:InvokeFunction --principal s3.amazonaws.com `
    --source-arn "arn:aws:s3:::$SourceBucket" --region $Region 2>$null | Out-Null

$FnArn = (aws lambda get-function --function-name $FunctionName --region $Region --query "Configuration.FunctionArn" --output text).Trim()
$notif = @{ LambdaFunctionConfigurations = @(@{ LambdaFunctionArn=$FnArn; Events=@("s3:ObjectCreated:*") }) } | ConvertTo-Json -Depth 10
$notifFile = Join-Path $env:TEMP "sip-notif.json"
[System.IO.File]::WriteAllText($notifFile, $notif, (New-Object System.Text.UTF8Encoding($false)))
aws s3api put-bucket-notification-configuration --bucket $SourceBucket --notification-configuration file://$notifFile --region $Region
Write-Host "    Trigger wired." -ForegroundColor Green

Remove-Item $trustFile,$permFile,$notifFile -ErrorAction SilentlyContinue

Write-Host "`n==================================================" -ForegroundColor Green
Write-Host " Deploy complete." -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Test it:"
Write-Host "   aws s3 cp invoices/invoice_1.png s3://$SourceBucket/"
Write-Host "   aws logs tail /aws/lambda/$FunctionName --follow --region $Region"
Write-Host "   aws dynamodb scan --table-name $TableName --limit 5 --region $Region"
Write-Host "`n NOTE: Textract AnalyzeExpense requires the AWS Paid plan." -ForegroundColor Yellow