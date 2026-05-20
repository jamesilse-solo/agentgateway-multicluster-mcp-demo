#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 06-rbac-and-registry.sh — Strict identity-bound path scoping
#
# Four checks:
#   1. tenant-a JWT hits /mcp/tenant-a → 200
#   2. tenant-a JWT hits /mcp/tenant-b → 401 (cross-tenant denied)
#   3. tenant-b JWT hits /mcp/tenant-b → 200
#   4. tenant-b JWT hits /mcp/tenant-a → 401
#
# Requires:
#   - 05b-multi-tenancy.sh (creates the tenant routes/backends)
#   - 05e-rbac-strict.sh   (per-tenant Dex clients + audience restriction)
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
banner() { echo -e "\n${M}━━━ $* ━━━${N}"; }
note()   { echo -e "  ${Y}↳ $*${N}"; }
ok()     { echo -e "  ${G}✓ $*${N}"; }
bad()    { echo -e "  \033[1;31m✗ $*${N}"; }

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

# Helper — acquire a token for a given user against a given client
get_token() {
  local user="$1" pass="$2" client_id="$3" client_secret="$4"
  curl -s -X POST "http://${AGW_LB}/dex/token" \
    -d 'grant_type=password' \
    -d "username=${user}" -d "password=${pass}" \
    -d "client_id=${client_id}" -d "client_secret=${client_secret}" \
    -d 'scope=openid email profile' | jq -r '.id_token // empty'
}

# Helper — initialize MCP and return HTTP status
init_status() {
  local path="$1" token="$2"
  curl -s -o /dev/null -w "%{http_code}" -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"06","version":"1"}}}'
}

banner "Step 1 — Acquire one JWT per tenant client"
TOKEN_A=$(get_token tenant-a-agent@example.com tenant-a-pass tenant-a-client tenant-a-client-secret)
TOKEN_B=$(get_token tenant-b-agent@example.com tenant-b-pass tenant-b-client tenant-b-client-secret)
[[ -z "${TOKEN_A}" ]] && { bad "tenant-a token acquisition failed (did you run scripts/05e-rbac-strict.sh?)"; exit 1; }
[[ -z "${TOKEN_B}" ]] && { bad "tenant-b token acquisition failed"; exit 1; }
ok "Both tokens acquired"

banner "Step 2 — Same-tenant calls (expect 200)"
HTTP=$(init_status /mcp/tenant-a "${TOKEN_A}")
[[ "${HTTP}" == "200" ]] && ok "tenant-a → /mcp/tenant-a: HTTP ${HTTP}" || bad "tenant-a → /mcp/tenant-a: HTTP ${HTTP}"
HTTP=$(init_status /mcp/tenant-b "${TOKEN_B}")
[[ "${HTTP}" == "200" ]] && ok "tenant-b → /mcp/tenant-b: HTTP ${HTTP}" || bad "tenant-b → /mcp/tenant-b: HTTP ${HTTP}"

banner "Step 3 — Cross-tenant calls (expect 401)"
HTTP=$(init_status /mcp/tenant-b "${TOKEN_A}")
[[ "${HTTP}" == "401" || "${HTTP}" == "403" ]] && ok "tenant-a → /mcp/tenant-b: HTTP ${HTTP} (blocked)" || bad "tenant-a → /mcp/tenant-b: HTTP ${HTTP} (expected 401/403)"
HTTP=$(init_status /mcp/tenant-a "${TOKEN_B}")
[[ "${HTTP}" == "401" || "${HTTP}" == "403" ]] && ok "tenant-b → /mcp/tenant-a: HTTP ${HTTP} (blocked)" || bad "tenant-b → /mcp/tenant-a: HTTP ${HTTP} (expected 401/403)"

banner "What just happened"
cat <<EOF
  1. Two tenant clients were configured in Dex, each with its own
     audience claim on issued JWTs.
  2. Each tenant backend's AgentgatewayPolicy declares
     authentication.audiences listing only its own client.
  3. A tenant-a JWT (aud=tenant-a-client) failed authentication on
     /mcp/tenant-b because the backend only accepts aud=tenant-b-client.
  4. The "path is convention" model of Package 1 is now hard
     enforcement — at the audience-claim level.

What this example does NOT do:
  - AgentRegistry write-API RBAC. Currently the registry has
    demoAuthEnabled: true (no real auth). Switching to OIDC-backed
    write scopes requires Helm-value changes on the agentregistry
    chart — out of scope for this example.
EOF
