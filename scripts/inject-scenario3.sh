#!/bin/bash
# Scenario 3: Missing Index / Stale Statistics
# Drops the customer_id index and leaves statistics stale
set -e

echo "=== Injecting Scenario 3: Missing Index / Stale Statistics ==="

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

echo ""
echo "1. Dropping index idx_orders_customer_id..."
run_sql "DROP INDEX IF EXISTS idx_orders_customer_id"

echo "2. Bulk-loading additional rows without ANALYZE..."
run_sql "INSERT INTO orders (customer_id, total, status)
SELECT (random() * 10000)::int, (random() * 500)::numeric(10,2), 'new'
FROM generate_series(1, 50000)"

echo ""
echo "=== Scenario 3 Injected ==="
echo ""
echo "The idx_orders_customer_id index is gone and statistics are stale."
echo "Queries filtering by customer_id will now do sequential scans."
echo ""
echo "Ask DevOps Agent:"
echo "  \"A specific endpoint that queries orders by customer_id has become very slow."
echo "   Overall database metrics look fine. Can you investigate?\""
