#!/usr/bin/env bash
#
# teardown.sh - Removes all resources created by deploy.sh.
# Mirrors teardown.ps1. Pulls account ID at runtime. Only touches the named
# resources - nothing else in your account.
#
# Usage:
#   ./teardown.sh
#   FORCE=1 ./teardown.sh            # skip the confirmation prompt
#   REGION=us-east-1 BUCKET_SUFFIX=mydemo ./teardown.sh
#
set -uo pipefail

REGION="${REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-invoice-processor}"
TABLE_NAME="${TABLE_NAME:-invoices}"
ROLE_NAME="${ROLE_NAME:-invoice-processor-role}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
[ -n "$ACCOUNT_ID" ] || { echo "Could not resolve AWS account. Are credentials configured?"; exit 1; }
BUCKET_SUFFIX="${BUCKET_SUFFIX:-$ACCOUNT_ID}"

SOURCE_BUCKET="invoice-source-${BUCKET_SUFFIX}"
OUTPUT_BUCKET="textract-ml-ai-${BUCKET_SUFFIX}"

echo "This will DELETE the following in account $ACCOUNT_ID ($REGION):"
echo "  - Lambda function : $FUNCTION_NAME"
echo "  - S3 buckets      : $SOURCE_BUCKET, $OUTPUT_BUCKET (and all contents)"
echo "  - IAM role        : $ROLE_NAME"
echo "  - DynamoDB table  : $TABLE_NAME"
if [ "${FORCE:-0}" != "1" ]; then
  read -r -p "Type 'yes' to proceed: " confirm
  [ "$confirm" = "yes" ] || { echo "Aborted."; exit 0; }
fi

echo ""
echo "==> Deleting Lambda function..."
if aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "    Deleted."
else
  echo "    Not found, skipping."
fi

echo ""
echo "==> Emptying + deleting S3 buckets..."
for b in "$SOURCE_BUCKET" "$OUTPUT_BUCKET"; do
  if aws s3api head-bucket --bucket "$b" >/dev/null 2>&1; then
    aws s3 rb "s3://$b" --force --region "$REGION" >/dev/null 2>&1 || true
    echo "    Removed $b"
  else
    echo "    $b not found, skipping."
  fi
done

echo ""
echo "==> Deleting IAM role..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  for arn in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text); do
    [ -n "$arn" ] && aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn" >/dev/null 2>&1 || true
  done
  for p in $(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[]' --output text); do
    [ -n "$p" ] && aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
  echo "    Deleted."
else
  echo "    Not found, skipping."
fi

echo ""
echo "==> Deleting DynamoDB table..."
if aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "    Delete requested."
else
  echo "    Not found, skipping."
fi

rm -f "$PROJECT_ROOT/function.zip"

echo ""
echo "=================================================="
echo " Teardown complete."
echo "=================================================="