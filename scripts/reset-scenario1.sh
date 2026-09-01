#!/bin/bash
# Reset Scenario 1: Restore sequence to a safe value
set -e

echo "=== Resetting Scenario 1: Sequence Exhaustion ==="

CLUSTER_ID=${CLUSTER_ID:-aurora-postgres-cluster-1}
MCP_STACK_NAME=${MCP_STACK_NAME:-aurora-mcp-server}
REGION=${AWS_REGION:-us-east-1}
CLUSTER_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query "DBClusters[0].DBClusterArn" --output text --region "$REGION")
SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "$MCP_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DBCredentialsSecretArn'].OutputValue" --output text --region "$REGION")

run_sql() {
  aws rds-data execute-statement \
    --resource-arn "$CLUSTER_ARN" \
    --secret-arn "$SECRET_ARN" \
    --database postgres \
    --region "$REGION" \
    --sql "$1" > /dev/null
}

echo "1. Resetting orders_id_seq to 100001..."
run_sql "ALTER SEQUENCE orders_id_seq RESTART WITH 100001"

echo "2. Verifying INSERT works..."
run_sql "INSERT INTO orders (customer_id, total) VALUES (1, 10.00)"

echo ""
echo "=== Scenario 1 Reset Complete ==="
echo "Inserts are working again. Ready for next demo run."
