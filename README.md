# ecs-cicd-infra

CloudFormation infrastructure for the ECS CI/CD lab — Eugene Anokye.

All resources are provisioned via **CloudFormation nested stacks** managed by **GitSync**.

---

## Architecture

```
GitHub (this repo)
       │
       ▼  GitSync
CloudFormation Master Stack
 ├── NetworkStack    → VPC, subnets, IGW, NAT, VPC endpoints
 ├── SecurityStack   → ALB SG, ECS SG (least-privilege)
 ├── ECRStack        → ECR repository (immutable tags, scan on push)
 ├── LoggingStack    → CloudWatch Log Group (/ecs/ecs-cicd)
 ├── IAMStack        → Task execution role, CodeDeploy, CodePipeline, GitHub OIDC
 ├── ECSStack        → Cluster, Task Def, ALB, Blue/Green TGs, Service, Auto Scaling
 ├── PipelineStack   → S3 artifacts, CodeDeploy B/G, CodePipeline, EventBridge
 └── MonitoringStack → CloudWatch Alarms + Dashboard
```

**Network layout:**

| Subnet | CIDR | AZ | Hosts |
|--------|------|----|-------|
| PublicSubnetA | 10.0.1.0/24 | AZ-a | ALB |
| PublicSubnetB | 10.0.2.0/24 | AZ-b | ALB |
| PrivateSubnetA | 10.0.11.0/24 | AZ-a | ECS Tasks |
| PrivateSubnetB | 10.0.12.0/24 | AZ-b | ECS Tasks |

VPC endpoints (ECR API, ECR DKR, S3, CloudWatch Logs) allow ECS tasks in private subnets to reach AWS services without traversing the internet.

---

## Deploy

### Prerequisites

- AWS CLI configured with admin access
- An S3 bucket for nested templates (create one if needed)

### Step 1 — Upload nested stack templates

```bash
./scripts/upload-templates.sh my-cfn-templates-bucket eu-central-1
```

### Step 2 — Deploy the master stack

```bash
aws cloudformation deploy \
  --template-file master.yaml \
  --stack-name ecs-cicd-master \
  --region eu-central-1 \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    GithubOrg=YOUR_GITHUB_USERNAME \
    GithubRepo=ecs-cicd-app \
    TemplatesBucket=my-cfn-templates-bucket
```

### Step 3 — Upload the initial deploy bundle

After the master stack is deployed (first time only, before any GitHub Actions run):

```bash
./scripts/upload-deploy-bundle.sh ecs-cicd-master eu-central-1
```

### Step 4 — Set up GitSync (optional, for automatic updates)

1. AWS Console → CloudFormation → **GitSync**
2. Link this repo → point at `deployment-config.yaml`
3. Future pushes to `main` will update the master stack automatically

### Step 5 — Configure GitHub Actions secret

Get the OIDC role ARN from the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name ecs-cicd-master \
  --query 'Stacks[0].Outputs[?OutputKey==`GitHubOIDCRoleArn`].OutputValue' \
  --output text
```

Add it as a **repository secret** in the app repo: `AWS_ROLE_ARN`

---

## Stack Outputs

| Output | Description |
|--------|-------------|
| `ALBEndpoint` | Public URL of the application |
| `ECRRepositoryUri` | ECR image URI prefix |
| `GitHubOIDCRoleArn` | Set as `AWS_ROLE_ARN` secret in the app repo |
| `ArtifactBucketName` | S3 bucket for pipeline artifacts |
| `CloudWatchDashboard` | Link to the CloudWatch dashboard |

---

## CI/CD Flow

```
git push → ECR image pushed by GitHub Actions
                │
                ▼ EventBridge (ECR Image Action)
          CodePipeline starts
                │
          ┌─────┴──────┐
          │             │
       ECR Source    S3 Source
    (imageDetail.json) (appspec + taskdef)
          │             │
          └─────┬──────┘
                ▼
        CodeDeploy Blue/Green
                │
         ┌──────┴──────┐
         │              │
      Blue TG        Green TG  ← new tasks deployed here
         │              │
         ALB Prod     ALB Test (port 8080 for validation)
         Listener      Listener
                │
         Traffic shifted Blue → Green
                │
         Blue tasks terminated after 5 min
```

---

## Security Notes

- ECS tasks run in **private subnets** with no public IPs
- ECS security group allows **only port 8080 from the ALB security group**
- GitHub Actions uses **OIDC** — no long-lived AWS credentials stored in GitHub
- ECR repository has **immutable tags** — pushed images cannot be overwritten
- S3 artifact bucket enforces **SSL-only access** and server-side encryption
