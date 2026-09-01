#!/bin/bash
# Setup test schema for DevOps Agent database troubleshooting scenarios
set -e

echo "=== Setting up test schema ==="

# Stack name and cluster id are overridable so this works regardless of what the
# stacks were named at deploy time.
CLUSTER_ID=${CLUSTER_ID:-aurora-postgres-cluster-1}
MCP_STACK_NAME=${MCP_STACK_NAME:-aurora-mcp-server}
REGION=${AWS_REGION:-us-east-1}

CLUSTER_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query "DBClusters[0].DBClusterArn" --output text --region "$REGION")
SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "$MCP_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DBCredentialsSecretArn'].OutputValue" --output text --region "$REGION")

run_sql() {
  echo "  Running: ${1:0:80}..."
  aws rds-data execute-statement \
    --resource-arn "$CLUSTER_ARN" \
    --secret-arn "$SECRET_ARN" \
    --database postgres \
    --region "$REGION" \
    --sql "$1" > /dev/null
}

echo ""
echo "1. Creating orders table..."
run_sql "CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    total NUMERIC(10, 2) NOT NULL,
    status VARCHAR(50) DEFAULT 'new',
    created_at TIMESTAMP DEFAULT now()
)"

echo "2. Creating index on orders..."
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON orders (customer_id)"

echo "3. Creating order_events table..."
run_sql "CREATE TABLE IF NOT EXISTS order_events (
    id BIGSERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(id),
    event_type VARCHAR(100),
    status VARCHAR(50),
    created_at TIMESTAMP DEFAULT now()
)"

echo "4. Seeding orders data (1000 rows)..."
run_sql "INSERT INTO orders (customer_id, total, status)
SELECT (random() * 10000)::int, (random() * 500)::numeric(10,2), 'new'
FROM generate_series(1, 1000)"

echo "5. Seeding order_events data (5000 rows)..."
run_sql "INSERT INTO order_events (order_id, event_type, status)
SELECT (random() * 1000)::int + 1, 'created', 'processed'
FROM generate_series(1, 5000)"

echo "6. Running ANALYZE..."
run_sql "ANALYZE orders"
run_sql "ANALYZE order_events"

echo ""
echo "=== Schema setup complete ==="
echo "Tables: orders, order_events"
echo "Indexes: idx_orders_customer_id"
echo "Ready for scenario injection."
