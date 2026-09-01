#!/bin/bash
# One-command deployment for AWS DevOps Agent for Databases demo
set -e

echo "=============================================="
echo " AWS DevOps Agent for AWS Databases"
echo " One-Command Deployment"
echo "=============================================="
echo ""

# Check prerequisites
command -v aws >/dev/null 2>&1 || { echo "ERROR: AWS CLI not found. Install it first."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found. Install it first."; exit 1; }

# Require VPC and subnet parameters. The DB master password is generated in
# Secrets Manager by the cluster stack, so no DB_PASSWORD is needed.
if [ -z "$VPC_ID" ] || [ -z "$SUBNET_ID_1" ] || [ -z "$SUBNET_ID_2" ]; then
  echo "Please set environment variables before running:"
  echo ""
  echo "  export VPC_ID=vpc-xxxxxxxxx"
  echo "  export SUBNET_ID_1=subnet-xxxxxxx"
  echo "  export SUBNET_ID_2=subnet-yyyyyyy"
  echo "  export AWS_REGION=us-east-1  (optional, defaults to us-east-1)"
  echo ""
  echo "The Aurora master password is generated and stored in Secrets Manager"
  echo "automatically; you do not supply it."
  echo ""
  echo "Then re-run: bash scripts/deploy-all.sh"
  exit 1
fi

REGION=${AWS_REGION:-us-east-1}
# Keep the MCP endpoint read-only by default. The demo's schema setup and
# scenario injection run SQL directly via the RDS Data API (see setup-schema.sh
# and inject-scenario*.sh), so the public MCP endpoint does not need write
# access. Set ALLOW_WRITE_QUERIES=true only if you explicitly want the endpoint
# to permit writes.
ALLOW_WRITE_QUERIES=${ALLOW_WRITE_QUERIES:-false}
echo "Region: $REGION"
echo "VPC: $VPC_ID"
echo "Subnets: $SUBNET_ID_1, $SUBNET_ID_2"
echo "MCP endpoint write queries: $ALLOW_WRITE_QUERIES"
echo ""

# Step 1: Deploy Aurora cluster (generates and stores the master password)
echo "=== Step 1/5: Deploying Aurora PostgreSQL cluster ==="
aws cloudformation create-stack \
  --stack-name aurora-postgres-cluster \
  --template-body file://cloudformation/aurora-postgresql-cluster.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=demo \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=SubnetId1,ParameterValue=$SUBNET_ID_1 \
    ParameterKey=SubnetId2,ParameterValue=$SUBNET_ID_2 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

echo "Waiting for cluster creation (~8-10 minutes)..."
aws cloudformation wait stack-create-complete --stack-name aurora-postgres-cluster --region $REGION
echo "✓ Aurora cluster created"
echo ""

# Retrieve the generated master-credentials secret ARN from the cluster stack.
MASTER_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name aurora-postgres-cluster \
  --query "Stacks[0].Outputs[?OutputKey=='MasterDBCredentialsSecretArn'].OutputValue" \
  --output text --region $REGION)

# Step 2: Deploy MCP server (consumes the generated master secret by ARN)
echo "=== Step 2/5: Deploying MCP server ==="
aws cloudformation create-stack \
  --stack-name aurora-mcp-server \
  --template-body file://cloudformation/aurora-postgresql-mcp-server.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=demo \
    ParameterKey=MasterDBCredentialsSecretArn,ParameterValue="$MASTER_SECRET_ARN" \
    ParameterKey=AllowWriteQueries,ParameterValue="$ALLOW_WRITE_QUERIES" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

echo "Waiting for MCP server creation (~3-5 minutes)..."
aws cloudformation wait stack-create-complete --stack-name aurora-mcp-server --region $REGION
echo "✓ MCP server created"
echo ""

# Step 3: Setup test schema
echo "=== Step 3/5: Setting up test schema ==="
bash scripts/setup-schema.sh
echo ""

# Step 4: Create the least-privilege DB role the MCP server authenticates as
echo "=== Step 4/5: Creating least-privilege MCP app role ==="
ENVIRONMENT=demo CLUSTER_ID=aurora-postgres-cluster-1 AWS_REGION=$REGION bash scripts/setup-readonly-role.sh
echo ""

# Step 5: Test connectivity
echo "=== Step 5/5: Testing connectivity ==="
bash scripts/test-connection.sh
echo ""

# Output
MCP_URL=$(aws cloudformation describe-stacks --stack-name aurora-mcp-server \
  --query "Stacks[0].Outputs[?OutputKey=='McpEndpointUrl'].OutputValue" --output text --region $REGION)

echo "=============================================="
echo " Deployment Complete"
echo "=============================================="
echo ""
echo "MCP Endpoint: $MCP_URL"
echo ""
echo "Next steps:"
echo "  1. Register the MCP server with DevOps Agent (see the 'Register with DevOps Agent' section in README.md)"
echo "  2. Run a scenario: bash scripts/inject-scenario1.sh"
echo "  3. Ask DevOps Agent to investigate"
echo ""
