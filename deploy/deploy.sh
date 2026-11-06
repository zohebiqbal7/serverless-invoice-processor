#!/usr/bin/env bash
#
# deploy.sh - Deploys the serverless-invoice-processor stack.
# Mirrors deploy.ps1. Pulls your AWS account ID at runtime (nothing hardcoded).
# Creates: DynamoDB table, S3 buckets, IAM role, Lambda function, and S3 trigger.
#
# NOTE: Amazon Textract (AnalyzeExpense) requires the AWS Paid plan. On the Free
# plan the stack deploys, but the OCR call returns SubscriptionRequiredException.
#
# Usage:
#   ./deploy.sh
#   REGION=us-east-1 BUCKET_SUFFIX=mydemo ./deploy.sh
#
set -euo pipefail

REGION="${REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-invoice-processor}"
TABLE_NAME="${TABLE_NAME:-invoices}"
ROLE_NAME="${ROLE_NAME:-invoice-processor-role}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"   # repo root (one level up from deploy/)

echo "==> Resolving AWS account..."
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[ -n "$ACCOUNT_ID" ] || { echo "Could not resolve AWS account. Are credentials configured?"; exit 1; }
BUCKET_SUFFIX="${BUCKET_SUFFIX:-$ACCOUNT_ID}"

SOURCE_BUCKET="invoice-source-${BUCKET_SUFFIX}"
OUTPUT_BUCKET="textract-ml-ai-${BUCKET_SUFFIX}"
echo "    Account:       $ACCOUNT_ID"
echo "    Region:        $REGION"
echo "    Source bucket: $SOURCE_BUCKET"
echo "    Output bucket: $OUTPUT_BUCKET"

# ---------------------------------------------------------------------------
echo ""
echo "==> [1/6] DynamoDB table '$TABLE_NAME'..."
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "    Already exists, skipping."
else
  aws dynamodb create-table --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=invoice_id,AttributeType=S \
    --key-schema AttributeName=invoice_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST --region "$REGION" >/dev/null
  echo "    Creating... waiting for ACTIVE"
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  echo "    Created."
fi

# ---------------------------------------------------------------------------
echo ""
echo "==> [2/6] S3 buckets..."
for b in "$SOURCE_BUCKET" "$OUTPUT_BUCKET"; do
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    echo "    $b already exists, skipping."
  else
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$b" --region "$REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$b" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
    fi
    echo "    Created $b"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "==> [3/6] IAM role '$ROLE_NAME'..."
TRUST_FILE="$(mktemp)"
PERM_FILE="$(mktemp)"
cat > "$TRUST_FILE" <<JSON
{ "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}] }
JSON
cat > "$PERM_FILE" <<JSON
{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:${REGION}:${ACCOUNT_ID}:*"},
    {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:HeadBucket"],"Resource":["arn:aws:s3:::${SOURCE_BUCKET}/*","arn:aws:s3:::${SOURCE_BUCKET}","arn:aws:s3:::${OUTPUT_BUCKET}/*","arn:aws:s3:::${OUTPUT_BUCKET}"]},
    {"Effect":"Allow","Action":"textract:AnalyzeExpense","Resource":"*"},
    {"Effect":"Allow","Action":"bedrock:InvokeModel","Resource":"arn:aws:bedrock:*::foundation-model/amazon.nova-micro-v1:0"},
    {"Effect":"Allow","Action":"dynamodb:PutItem","Resource":"arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"}
  ]
}
JSON
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "    Role exists, updating policy."
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$TRUST_FILE" >/dev/null
  echo "    Created role."
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "${FUNCTION_NAME}-permissions" --policy-document "file://$PERM_FILE" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
echo "    Role ARN: $ROLE_ARN"
echo "    Waiting for IAM propagation (10s)..."
sleep 10

# ---------------------------------------------------------------------------
echo ""
echo "==> [4/6] Packaging + deploying Lambda '$FUNCTION_NAME'..."
ZIP="$PROJECT_ROOT/function.zip"
( cd "$PROJECT_ROOT" && zip -j -q "$ZIP" lambda_function.py )
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION_NAME" --zip-file "fileb://$ZIP" --region "$REGION" >/dev/null
  echo "    Updated function code."
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
else
  aws lambda create-function --function-name "$FUNCTION_NAME" --runtime python3.12 \
    --handler lambda_function.lambda_handler --role "$ROLE_ARN" \
    --zip-file "fileb://$ZIP" --timeout 120 --memory-size 256 --region "$REGION" >/dev/null
  echo "    Created function."
  aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==> [5/6] Setting environment variable..."
aws lambda update-function-configuration --function-name "$FUNCTION_NAME" \
  --environment "Variables={TEXTRACT_OUTPUT_BUCKET=$OUTPUT_BUCKET}" --region "$REGION" >/dev/null
aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
echo "    TEXTRACT_OUTPUT_BUCKET=$OUTPUT_BUCKET"

# ---------------------------------------------------------------------------
echo ""
echo "==> [6/6] Wiring S3 trigger..."
aws lambda add-permission --function-name "$FUNCTION_NAME" --statement-id s3invoke \
  --action lambda:InvokeFunction --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$SOURCE_BUCKET" --region "$REGION" >/dev/null 2>&1 || true
FN_ARN="$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" --query 'Configuration.FunctionArn' --output text)"
NOTIF_FILE="$(mktemp)"
cat > "$NOTIF_FILE" <<JSON
{ "LambdaFunctionConfigurations":[{"LambdaFunctionArn":"$FN_ARN","Events":["s3:ObjectCreated:*"]}] }
JSON
aws s3api put-bucket-notification-configuration --bucket "$SOURCE_BUCKET" --notification-configuration "file://$NOTIF_FILE" --region "$REGION"
echo "    Trigger wired."

rm -f "$TRUST_FILE" "$PERM_FILE" "$NOTIF_FILE"

echo ""
echo "=================================================="
echo " Deploy complete."
echo "=================================================="
echo " Test it:"
echo "   aws s3 cp invoices/invoice_1.png s3://$SOURCE_BUCKET/"
echo "   aws logs tail /aws/lambda/$FUNCTION_NAME --follow --region $REGION"
echo "   aws dynamodb scan --table-name $TABLE_NAME --limit 5 --region $REGION"
echo ""
echo " NOTE: Textract AnalyzeExpense requires the AWS Paid plan."