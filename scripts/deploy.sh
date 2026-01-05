#!/bin/bash

# TODO: It deploys one environment (dev/test/prod) of the system in a single command.
# Step-by-step summary
# Select environment and project
# Build the Lambda artifact
# Initialize and apply Terraform
# Applies infrastructure:
#    Provisions AWS resources (Lambda, API Gateway, S3, CloudFront, IAM, etc.).
# Read Terraform outputs
# Build and deploy the frontend
# Print deployment results

set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

cd "$(dirname "$0")/.."        # project root

OPENAI_VAR_FILE="terraform/terraform.tfvars"
[ "$ENVIRONMENT" = "prod" ] && OPENAI_VAR_FILE="terraform/prod.tfvars"

if [ -z "${TF_VAR_openai_api_key:-}" ]; then
  if [ ! -f "$OPENAI_VAR_FILE" ] || ! grep -q "openai_api_key" "$OPENAI_VAR_FILE"; then
    echo "Error: openai_api_key is required. Set TF_VAR_openai_api_key or add it to $OPENAI_VAR_FILE"
    exit 1
  fi
fi

# 1. Build Lambda package
echo "Building Lambda package..."
(cd backend && uv run --active deploy.py)

# 2. Terraform workspace & apply
cd terraform
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

# Use prod.tfvars for production environment
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
fi

echo "Applying Terraform..."
"${TF_APPLY_CMD[@]}"

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

# Create production environment file with API URL
echo "Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final messages
echo -e "\nDeployment complete!"
echo "CloudFront URL : $(terraform -chdir=terraform output -raw cloudfront_url)"
if [ -n "$CUSTOM_URL" ]; then
  echo "Custom domain: $CUSTOM_URL"
fi
echo "API Gateway: $API_URL"


# check mermaid workflow diagram to ge better picture:
# flowchart TD
#   A([Start: deploy.sh]) --> B["Parse inputs<br/>ENVIRONMENT: dev/test/prod (default dev)<br/>PROJECT_NAME (default twin)"]
#   B --> C["Fail-fast: set -e"]

#   C --> D["cd to project root (relative to script)"]
#   D --> E["Build backend artifact<br/>(cd backend; uv run --active deploy.py)"]

#   E --> F["cd terraform/"]
#   F --> G["terraform init -input=false"]

#   G --> H{"Workspace exists?"}
#   H -- "No" --> I["terraform workspace new ENVIRONMENT"]
#   H -- "Yes" --> J["terraform workspace select ENVIRONMENT"]
#   I --> K{"ENVIRONMENT == prod?"}
#   J --> K

#   K -- "Yes" --> L["terraform apply<br/>-var-file=prod.tfvars<br/>-var project_name<br/>-var environment<br/>-auto-approve"]
#   K -- "No" --> M["terraform apply<br/>-var project_name<br/>-var environment<br/>-auto-approve"]

#   L --> N["Read outputs<br/>API_URL, FRONTEND_BUCKET, CUSTOM_URL (optional)"]
#   M --> N

#   N --> O["cd frontend/"]
#   O --> P["Write .env.production<br/>NEXT_PUBLIC_API_URL=API_URL"]
#   P --> Q["npm install"]
#   Q --> R["npm run build"]
#   R --> S["aws s3 sync ./out to s3://FRONTEND_BUCKET/ --delete"]

#   S --> T["Print URLs<br/>CloudFront, Custom domain (if any), API Gateway"]
#   T --> U([End])
