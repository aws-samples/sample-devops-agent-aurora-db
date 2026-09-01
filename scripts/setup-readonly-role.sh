#!/bin/bash
# Create the least-privilege PostgreSQL role that the MCP server authenticates as.
#
# The MCP server (public endpoint) uses the app credentials in the
# /<env>/postgres-mcp-server/app-db-credentials secret via the RDS Data API.
# That role must exist in PostgreSQL with the exact password stored in the
# secret, and should hold only read (or narrowly scoped) privileges — never the
# master/superuser role.
#
# This script runs the DDL as the master user (master DB-credentials secret),
# reading the app role name and password from the app-db-credentials secret.
# Run it once after deploying the MCP server stack, and re-run it if you rotate
# the app secret.
set -euo pipefail

ENVIRONMENT=${ENVIRONMENT:-demo}
CLUSTER_ID=${CLUSTER_ID:-aurora-postgres-cluster-1}
DATABASE=${DATABASE:-postgres}
REGION=${AWS_REGION:-us-east-1}
MCP_STACK_NAME=${MCP_STACK_NAME:-aurora-mcp-server}

echo "=== Setting up least-privilege MCP app role ==="
echo "Environment: $ENVIRONMENT | Cluster: $CLUSTER_ID | DB: $DATABASE | Region: $REGION"

CLUSTER_ARN=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
  --query "DBClusters[0].DBClusterArn" --output text --region "$REGION")

# Master credentials secret (used only to run this bootstrap DDL).
MASTER_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "$MCP_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DBCredentialsSecretArn'].OutputValue" \
  --output text --region "$REGION")

# App credentials secret (what the MCP server actually uses).
APP_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name "$MCP_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='AppDbCredentialsSecretArn'].OutputValue" \
  --output text --region "$REGION")

APP_JSON=$(aws secretsmanager get-secret-value --secret-id "$APP_SECRET_ARN" \
  --query "SecretString" --output text --region "$REGION")
APP_USER=$(printf '%s' "$APP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['username'])")
APP_PASS=$(printf '%s' "$APP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")

# Basic identifier validation (defense against unexpected values in the secret).
if ! printf '%s' "$APP_USER" | grep -Eq '^[a-z_][a-z0-9_]*$'; then
  echo "ERROR: app username '$APP_USER' is not a valid PostgreSQL identifier." >&2
  exit 1
fi

run_master_sql() {
  aws rds-data execute-statement \
    --resource-arn "$CLUSTER_ARN" \
    --secret-arn "$MASTER_SECRET_ARN" \
    --database "$DATABASE" \
    --region "$REGION" \
    "$@" > /dev/null
}

echo "1. Creating/updating role $APP_USER (LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE)..."
# Create the role if missing, then set the password. The password is passed as a
# Data API parameter to avoid SQL injection / shell-quoting issues.
run_master_sql --sql "DO \$do\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    CREATE ROLE ${APP_USER} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END
\$do\$;"

run_master_sql \
  --sql "ALTER ROLE ${APP_USER} WITH PASSWORD :pw LOGIN" \
  --parameters "[{\"name\":\"pw\",\"value\":{\"stringValue\":\"${APP_PASS}\"}}]"

echo "2. Granting read-only privileges on database $DATABASE / schema public..."
run_master_sql --sql "GRANT CONNECT ON DATABASE ${DATABASE} TO ${APP_USER}"
run_master_sql --sql "GRANT USAGE ON SCHEMA public TO ${APP_USER}"
run_master_sql --sql "GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${APP_USER}"
# Ensure future tables are also readable.
run_master_sql --sql "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${APP_USER}"
# Allow reading sequence/catalog state used by the troubleshooting scenarios.
run_master_sql --sql "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ${APP_USER}"
run_master_sql --sql "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO ${APP_USER}"

echo ""
echo "=== Done ==="
echo "The MCP server will authenticate as '$APP_USER' (read-only) via the Data API."
echo "This role has no write or DDL privileges. Writes through the MCP endpoint are"
echo "blocked both by the read-only transaction AND by this role's grants."
