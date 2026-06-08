#!/usr/bin/env bash
# Upload nested CloudFormation templates to S3 before deploying the master stack.
# Usage: ./scripts/upload-templates.sh <bucket-name> [region]
set -euo pipefail

BUCKET="${1:?Usage: $0 <bucket-name> [region]}"
REGION="${2:-eu-central-1}"
PREFIX="stacks"

echo "Creating bucket (if not exists): s3://${BUCKET}"
aws s3api create-bucket \
  --bucket "${BUCKET}" \
  --region "${REGION}" \
  --create-bucket-configuration LocationConstraint="${REGION}" 2>/dev/null || true

aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "Uploading nested stack templates..."
for template in stacks/*.yaml; do
  echo "  ↑ ${template}"
  aws s3 cp "${template}" "s3://${BUCKET}/${PREFIX}/$(basename "${template}")" \
    --region "${REGION}" \
    --sse AES256
done

echo ""
echo "Done. Now deploy master.yaml with:"
echo ""
echo "  aws cloudformation deploy \\"
echo "    --template-file master.yaml \\"
echo "    --stack-name ecs-cicd-master \\"
echo "    --region ${REGION} \\"
echo "    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \\"
echo "    --parameter-overrides \\"
echo "      GithubOrg=YOUR_GITHUB_USERNAME \\"
echo "      GithubRepo=ecs-cicd-app \\"
echo "      TemplatesBucket=${BUCKET}"
