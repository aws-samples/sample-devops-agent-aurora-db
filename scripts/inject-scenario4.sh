#!/bin/bash
# Scenario 4: Inactive Logical Replication Slot / WAL Accumulation
# Creates a replication slot with no consumer
set -e

echo "=== Injecting Scenario 4: Inactive Replication Slot ==="

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
echo "1. Creating logical replication slot (no consumer)..."
run_sql "SELECT pg_create_logical_replication_slot('cdc_slot', 'pgoutput')"

echo "2. Generating WAL with writes (simulating ongoing traffic)..."
for i in 1 2 3 4 5; do
  echo "   Batch $i/5..."
  run_sql "UPDATE orders SET status = 'reprocess' WHERE id % 5 = $i"
done

echo ""
echo "=== Scenario 4 Injected ==="
echo ""
echo "A logical replication slot 'cdc_slot' is created but never consumed."
echo "WAL will accumulate and storage will gradually fill."
echo ""
echo "Ask DevOps Agent:"
echo "  \"Storage on aurora-postgres-cluster-1 is gradually increasing but we haven't"
echo "   added much data. CloudWatch shows falling FreeStorageSpace. Can you investigate?\""
