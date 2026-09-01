#!/bin/bash
# Cleanup all resources created by this demo
set -e

echo "=== Cleaning up AWS DevOps Agent for Databases demo ==="
echo ""
echo "WARNING: This will delete ALL resources. Press Ctrl+C to abort."
echo "Waiting 5 seconds..."
sleep 5

echo ""
echo "1. Deleting MCP server stack..."
aws cloudformation delete-stack --stack-name aurora-mcp-server 2>/dev/null || true
aws cloudformation wait stack-delete-complete --stack-name aurora-mcp-server 2>/dev/null || true
echo "   ✓ MCP server stack deleted"

echo ""
echo "2. Deleting Aurora cluster stack..."
aws cloudformation delete-stack --stack-name aurora-postgres-cluster 2>/dev/null || true
aws cloudformation wait stack-delete-complete --stack-name aurora-postgres-cluster 2>/dev/null || true
echo "   ✓ Aurora cluster stack deleted"

echo ""
echo "3. Cleaning up any orphaned secrets..."
aws secretsmanager delete-secret --secret-id /demo/postgres-mcp-server/api-key --force-delete-without-recovery 2>/dev/null || true
aws secretsmanager delete-secret --secret-id /demo/postgres-mcp-server/db-credentials --force-delete-without-recovery 2>/dev/null || true
echo "   ✓ Secrets cleaned up"

echo ""
echo "=== Cleanup complete ==="
