#!/bin/bash
# Scenario 1: Sequence Exhaustion - Integer PK Overflow
# Fast-forwards orders_id_seq to the int4 ceiling (2,147,483,647)
set -e

echo "=== Injecting Scenario 1: Sequence Exhaustion ==="

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
    --sql "$1"
}

echo ""
echo "1. Fast-forwarding orders_id_seq to near int4 max..."
run_sql "ALTER SEQUENCE orders_id_seq RESTART WITH 2147483646" > /dev/null

echo "2. Inserting row (id = 2147483646)..."
run_sql "INSERT INTO orders (customer_id, total) VALUES (1, 10.00)" > /dev/null

echo "3. Inserting row (id = 2147483647 — max int4)..."
run_sql "INSERT INTO orders (customer_id, total) VALUES (1, 10.00)" > /dev/null

echo ""
echo "=== Scenario 1 Injected ==="
echo ""
echo "The sequence is now exhausted. The next INSERT will fail with:"
echo "  ERROR: nextval: reached maximum value of sequence \"orders_id_seq\" (2147483647)"
echo ""
echo "CloudWatch metrics will show ALL GREEN."
echo ""
echo "Ask DevOps Agent:"
echo "  \"Our orders service is failing on inserts with errors. All CloudWatch metrics"
echo "   for cluster aurora-postgres-cluster-1 look normal — CPU, connections, and IOPS"
echo "   are all green. Can you investigate what's wrong?\""
