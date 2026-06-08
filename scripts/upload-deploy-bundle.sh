#!/usr/bin/env bash
# Upload the initial deploy bundle (appspec.yaml + taskdef.json) to S3.
# Run this ONCE after the master stack is deployed, before the first GitHub Actions push.
#
# Usage: ./scripts/upload-deploy-bundle.sh <master-stack-name> [region]
set -euo pipefail

STACK_NAME="${1:-ecs-cicd-master}"
REGION="${2:-eu-central-1}"

echo "Fetching stack outputs from: ${STACK_NAME}"

ARTIFACT_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' \
  --output text)

TASK_EXEC_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[?OutputKey==`GitHubOIDCRoleArn`].OutputValue' \
  --output text)

# Resolve the actual task execution role ARN from the ECS nested stack
TASK_EXEC_ROLE=$(aws iam get-role \
  --role-name ecs-cicd-task-execution-role \
  --query 'Role.Arn' \
  --output text 2>/dev/null || echo "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ecs-cicd-task-execution-role")

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Artifact bucket: ${ARTIFACT_BUCKET}"
echo "Task execution role: ${TASK_EXEC_ROLE}"

TMPDIR=$(mktemp -d)
trap 'rm -rf ${TMPDIR}' EXIT

# Generate appspec.yaml
cat > "${TMPDIR}/appspec.yaml" << 'EOF'
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>
        LoadBalancerInfo:
          ContainerName: "app"
          ContainerPort: 8080
        PlatformVersion: "LATEST"
EOF

# Generate taskdef.json with IMAGE1_NAME placeholder
cat > "${TMPDIR}/taskdef.json" << EOF
{
  "family": "ecs-cicd-app",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${TASK_EXEC_ROLE}",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "<IMAGE1_NAME>",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/ecs-cicd",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "app"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/ || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
EOF

# Placeholder imageDetail.json — GitHub Actions overwrites this on every push
cat > "${TMPDIR}/imageDetail.json" << EOF
{"ImageURI": "PLACEHOLDER_REPLACE_ON_FIRST_PUSH"}
EOF

echo "Creating deploy-bundle.zip..."
(cd "${TMPDIR}" && zip -q deploy-bundle.zip appspec.yaml taskdef.json imageDetail.json)

echo "Uploading to s3://${ARTIFACT_BUCKET}/deploy/deploy-bundle.zip"
aws s3 cp "${TMPDIR}/deploy-bundle.zip" \
  "s3://${ARTIFACT_BUCKET}/deploy/deploy-bundle.zip" \
  --region "${REGION}" \
  --sse AES256

echo ""
echo "Deploy bundle uploaded successfully."
echo "The pipeline is ready. Push an image to ECR to trigger a deployment."
