# Threat Model — Aurora PostgreSQL MCP Server for AWS DevOps Agent

**Scope:** the Aurora demo's own infrastructure and code in `aws-devops-agent-databases-main` — the Aurora cluster template, the MCP server (Lambda + API Gateway + Secrets Manager), the DevOps Agent integration template, and the deployment/injection scripts.
**Methodology:** STRIDE, decomposed by data flow and trust boundary.
**Status:** Records the intended remediated end state. The controls described below are implemented in the current working tree and must be committed and pushed so a reviewer can verify them against a specific commit. Until that commit exists, the "Resolved"/"Mitigated" rows describe the tree in this workspace, not necessarily any published commit. No HIGH or MEDIUM findings remain open in the reviewed tree.

> Note: This assessment covers the Aurora demo's own MCP Lambda and infrastructure (the code in the workspace). It does not cover the separate internal `ThreatModelingMCPServer` package. All findings are from static analysis of the templates and scripts; nothing was deployed or executed against AWS.
>
> **Commit / scan reconciliation:** verify this model against the commit that contains these changes (not an earlier commit such as `1897b711`, which predates the remediation). When attaching scan evidence, confirm the scanned artifact name matches this repository so results line up, and attach the raw Holmes/scan output to the review ticket rather than a dashboard link.

---

## 1. System decomposition

### Components
- **API Gateway HTTP API v2** — public HTTPS endpoint `POST/GET /mcp`, internet-facing.
- **Authorizer Lambda** — REQUEST authorizer; compares the `Authorization` header to an API key from Secrets Manager (constant-time; accepts current + previous key).
- **MCP Lambda** (`index.lambda_handler`) — JSON-RPC handler exposing 6 tools; runs SQL via RDS Data API as a least-privilege role.
- **API Key Rotation Lambda** — Secrets Manager 4-step rotation for the API key.
- **RDS Data API** — executes SQL against Aurora using credentials from Secrets Manager.
- **Aurora PostgreSQL Serverless v2** — the data store; `StorageEncrypted: true`, in-VPC.
- **Secrets Manager** — three secrets: master DB credentials (generated), least-privilege app DB credentials (generated), and the API key (generated + rotated). Encrypted with a customer-managed KMS CMK.
- **AWS DevOps Agent** — external caller holding the API key.
- **Operator scripts** — `deploy-all.sh`, `setup-schema.sh`, `setup-readonly-role.sh`, `test-connection.sh`, `inject-scenario*.sh`, `reset-*.sh`, `cleanup.sh`.

### Trust boundaries
1. Internet → API Gateway (primary boundary; the endpoint is public).
2. API Gateway → Authorizer / MCP Lambda (AWS-managed invoke).
3. MCP Lambda → RDS Data API → Aurora (IAM + secret-scoped, least-privilege role).
4. Lambda → Secrets Manager → KMS.
5. Operator workstation → AWS control plane (CLI credentials).

### Key assets
- Aurora data and DB credentials (master + least-privilege app role).
- The MCP API key (bearer credential guarding the endpoint).
- The ability to run SQL through `execute_query` (read-only by default).

---

## 2. Posture evolution

| ID | Finding | Original | Final | Status |
|----|---------|----------|-------|--------|
| H1 | Arbitrary SQL / writes as master user | HIGH | LOW | Mitigated (4 layers) |
| H2 | Public endpoint, weak key auth | HIGH | LOW–MED | Mitigated |
| H3 | API key logging / exposure | HIGH | LOW | Mitigated |
| M1 | Broad RDS Data API IAM scope | MED | — | Resolved |
| M2 | Account-wide KMS decrypt | MED | — | Resolved |
| M3 | DB master password as plaintext param | MED | — | Resolved |
| M4 | Agent integration key as plaintext param | MED | — | Resolved |
| L4 | No SQL audit trail | LOW | — | Resolved |
| — | No API key rotation | — | — | Resolved (auto rotation, dual-key) |
| — | No query cost guard | — | — | Resolved (statement_timeout) |
| N1 | Deploy-time app-role coupling | (new) | LOW | Accepted + documented |

---

## 3. Findings and controls

### H1 — Arbitrary SQL execution / writes as master user (HIGH → LOW)
**Original risk:** `execute_query` passed arbitrary SQL to the Data API as the Aurora master user, and the one-command deploy enabled writes. A substring keyword blocklist was the only guard and was trivially bypassable.
**Controls now in place (defense-in-depth):**
1. `is_read_only_sql()` allowlist — strips leading comments, rejects multiple statements, requires a read-only leading verb.
2. `SET TRANSACTION READ ONLY` — the database rejects any write in the disabled-writes path regardless of SQL construction.
3. **Least-privilege DB role** — the endpoint authenticates as `mcp_app` (SELECT-only; created by `setup-readonly-role.sh`). Master credentials are not reachable from the endpoint's IAM.
4. `statement_timeout` (default 30s) bounds query cost/runaway reads.
- Writes are **off by default** (`AllowWriteQueries=false`); `deploy-all.sh` no longer forces `true`.

**Residual (LOW):** the tool is a full SQL *reader* by design — disclosure of readable tables is inherent. The `mcp_app` grants cap what is selectable.

### H2 — Public endpoint with static bearer-key auth (HIGH → LOW–MED)
**Original risk:** public endpoint guarded only by a static API key compared with `==` (timing side channel); no rate limiting or source restriction.
**Controls now in place:**
- Constant-time comparison (`hmac.compare_digest`); `Bearer` scheme tolerated.
- **WAF WebACL** — per-IP rate-based rule + AWS managed `CommonRuleSet` and `KnownBadInputsRuleSet`.
- **Stage throttling** — rate + burst limits on the API stage.
- **Automatic key rotation** with a **dual-key authorizer** (accepts `AWSCURRENT` and `AWSPREVIOUS`) so rotation is non-disruptive.

**Residual (LOW–MED):** single shared bearer key with no per-caller identity and no source restriction. Rotation bounds the exposure window. An IP allowlist or PrivateLink would be the next reduction if the agent's egress is knowable (accepted for a demo).

### H3 — API key logging / exposure (HIGH → LOW)
**Controls now in place:** the MCP and authorizer Lambdas never log headers or the token; `test-connection.sh` uses the `Bearer` scheme.
**Residual (LOW, latent):** API Gateway access logging is not configured; if enabled, exclude the `Authorization` header.

### M1 — Broad RDS Data API IAM scope (MED → Resolved)
RDS Data API actions scoped to a single `cluster:${ClusterIdentifier}` ARN; the unused `rds-db:connect` statement removed.

### M2 — Account-wide KMS decrypt (MED → Resolved)
`kms:Decrypt`/`DescribeKey` scoped to the specific customer-managed key across the MCP, authorizer, and rotation roles.

### M3 — DB master password as a plaintext parameter (MED → Resolved)
The Aurora master password is generated by Secrets Manager in the cluster stack and read via a `{{resolve:secretsmanager:...}}` dynamic reference. It is never a CloudFormation/CLI parameter. The MCP stack consumes the secret by ARN.

### M4 — Agent integration key as a plaintext parameter (MED → Resolved)
`devops-agent-integration.yaml` resolves the API key from Secrets Manager dynamically (`McpApiKeySecretArn`) instead of taking a plaintext value.

### L4 — No SQL audit trail (LOW → Resolved)
Structured `execute_sql` audit logging (cluster, database, read_only flag, 200-char SQL prefix); no secrets or headers logged.

### N1 — Deploy-time app-role coupling (new, LOW / availability)
The `mcp_app` role must be bootstrapped (`setup-readonly-role.sh`) before `execute_query` works. `deploy-all.sh` handles ordering; documented in the README. Fail-closed.

### Unchanged low-severity items
- **L2** — operator scripts run privileged DML with the master secret (expected for a demo).
- **L3** — `cleanup.sh` force-deletes secrets after a 5s sleep.
- **L5** — cluster storage uses the default RDS KMS key (a CMK would be stronger for production).

---

## 4. Residual risk register

| ID | Residual | Severity | Disposition |
|----|----------|----------|-------------|
| H2 | Single shared key, no source restriction | LOW–MED | Accepted (demo); mitigated by rotation. Consider IP allowlist / PrivateLink for production. |
| H1 | Inherent SQL read access | LOW | Accepted (tool purpose); capped by `mcp_app` grants. |
| N1 | App-role bootstrap required before endpoint works | LOW | Accepted; documented; automated in `deploy-all.sh`. |
| — | Rotation registration refresh | LOW (availability) | Documented: update the DevOps Agent registration within one rotation interval. |
| L2/L3/L5 | Operator scripts, force-delete, default DB KMS key | LOW | Accepted for demo. |

---

## 5. Recommendations for production

1. Add a **source restriction** on the endpoint (IP allowlist or PrivateLink) if the DevOps Agent egress is knowable — the last meaningful reduction for H2.
2. Enable **API Gateway access logging** with the `Authorization` header excluded.
3. Use a **customer-managed KMS key** for the Aurora storage volume (L5).
4. Automate the **rotation registration refresh** so the DevOps Agent always holds a current key.

---

## 6. Verification

**Performed (static):**
- All three CloudFormation templates parse; all three inline Lambda bodies compile.
- Parameter/resource/output rewiring confirmed: dynamic master-password reference, MCP output wired to the secret ARN parameter, integration key as a dynamic reference, rotation resources present, IAM/KMS scopes tightened.
- All affected scripts pass `bash -n`.
- README updated to match the generated-secret, app-role, and rotation flow.

**Not verified (requires a deployment):**
- Runtime behaviors — the read-only transaction rejecting a crafted write, WAF/throttle enforcement, the 4-step rotation end-to-end, and the `mcp_app` login working through the Data API — are validated statically only. A deploy in a throwaway account is the way to confirm them.

---

*Generated as the final record of the threat-modeling and remediation work for this project.*
