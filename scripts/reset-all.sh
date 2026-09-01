#!/bin/bash
# Reset all scenarios to a clean state
set -e

echo "=== Resetting All Scenarios ==="

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
    --sql "$1" > /dev/null 2>&1 || true
}

echo ""
echo "1. Scenario 1: Resetting sequence..."
run_sql "ALTER SEQUENCE orders_id_seq RESTART WITH 100001"

echo "2. Scenario 2: Re-enabling autovacuum and running VACUUM..."
run_sql "ALTER TABLE order_events SET (autovacuum_enabled = true)"
run_sql "VACUUM (ANALYZE) order_events"

echo "3. Scenario 3: Re-creating index and running ANALYZE..."
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON orders (customer_id)"
run_sql "ANALYZE orders"

echo "4. Scenario 4: Dropping replication slot..."
run_sql "SELECT pg_drop_replication_slot('cdc_slot')"

echo ""
echo "=== All Scenarios Reset ==="
echo "Environment is clean for the next demo run."
