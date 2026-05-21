#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 02-multi-tenancy.sh
#
# WHAT THIS EXAMPLE SHOWS
# -----------------------
# Two distinct tenants (tenant-a, tenant-b) share one AgentGateway. Each
# tenant has its own URL path, its own tool allowlist, and (declaratively)
# its own rate limit. From the agent's view there is still one gateway —
# the differentiation is enforced inside it.
#
#   - tenant-a-agent calls  http://<lb>/mcp/tenant-a  → sees ALL tools
#                                                       → rate cap: 1000/min
#   - tenant-b-agent calls  http://<lb>/mcp/tenant-b  → sees only 2 tools
#                                                       → rate cap: 5/min
#
# WHAT YOU NEED FIRST
# -------------------
#   - scripts/03-dex.sh                — adds tenant-a-agent + tenant-b-agent users
#   - scripts/05-extauth.sh            — Dex + ExtAuth OIDC wired up
#   - scripts/05b-multi-tenancy.sh     — creates the per-tenant routes/policies
#
# Usage:
#   ./examples/02-multi-tenancy.sh
###############################################################################

# ─── Parameters ───────────────────────────────────────────────────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

# Color output
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
banner() { echo -e "\n${M}━━━ $* ━━━${N}"; }
note()   { echo -e "  ${Y}↳ $*${N}"; }
ok()     { echo -e "  ${G}✓ $*${N}"; }

###############################################################################
# Step 0 — Resolve the AGW LB
###############################################################################
banner "Step 0 — Resolve the AGW Hub LoadBalancer"
AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
note "AGW Hub: http://${AGW_LB}"

###############################################################################
# Step 1 — Acquire a JWT for each tenant
###############################################################################
banner "Step 1 — Acquire one JWT per tenant"

get_token() {
  curl -s -X POST "http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/token" \
    -d 'grant_type=password' \
    -d "username=$1" -d "password=$2" \
    -d 'client_id=agw-client' -d 'client_secret=agw-client-secret' \
    -d 'scope=openid email profile' \
    | jq -r '.id_token'
}

note "Acquiring token as tenant-a-agent..."
TOKEN_A=$(get_token tenant-a-agent tenant-a-pass)
[[ -z "${TOKEN_A}" || "${TOKEN_A}" == "null" ]] && { echo "✗ tenant-a token acquisition failed"; exit 1; }
ok "tenant-a token acquired (length ${#TOKEN_A})"

note "Acquiring token as tenant-b-agent..."
TOKEN_B=$(get_token tenant-b-agent tenant-b-pass)
[[ -z "${TOKEN_B}" || "${TOKEN_B}" == "null" ]] && { echo "✗ tenant-b token acquisition failed"; exit 1; }
ok "tenant-b token acquired (length ${#TOKEN_B})"

###############################################################################
# Step 2 — Hit each tenant's MCP endpoint, count visible tools
###############################################################################
banner "Step 2 — Tools visible to each tenant on their own MCP path"

count_tools() {
  local path="$1" token="$2"
  local RESP SID
  RESP=$(curl -si -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"02-mt","version":"1"}}}')
  SID=$(echo "$RESP" | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')
  curl -s -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: ${SID}" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | grep -o 'data:.*' | head -1 | sed 's/^data: //' \
    | jq -r '.result.tools | map(.name) | join(", ")' 2>/dev/null
}

note "Calling /mcp/tenant-a as tenant-a..."
A_TOOLS=$(count_tools /mcp/tenant-a "${TOKEN_A}")
A_COUNT=$(echo "${A_TOOLS}" | tr ',' '\n' | wc -l | tr -d ' ')
ok "tenant-a sees ${A_COUNT} tools"
echo -e "      ${C}${A_TOOLS}${N}"

note "Calling /mcp/tenant-b as tenant-b..."
B_TOOLS=$(count_tools /mcp/tenant-b "${TOKEN_B}")
B_COUNT=$(echo "${B_TOOLS}" | tr ',' '\n' | wc -l | tr -d ' ')
ok "tenant-b sees ${B_COUNT} tools"
echo -e "      ${C}${B_TOOLS}${N}"

###############################################################################
# Step 3 — Show the per-tenant policy YAML (the declarative intent)
###############################################################################
banner "Step 3 — Inspect the policy resources"

note "tenant-a EnterpriseAgentgatewayPolicy (auth + rate-limit declaration):"
${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy multi-tenancy-tenant-a \
  -o jsonpath='{.spec.traffic}' | jq -C '.' | sed 's/^/      /'

note "tenant-b EnterpriseAgentgatewayPolicy:"
${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy multi-tenancy-tenant-b \
  -o jsonpath='{.spec.traffic}' | jq -C '.' | sed 's/^/      /'

note "tenant-b's tool-RBAC AgentgatewayPolicy:"
${KC} -n "${AGW_NAMESPACE}" get agentgatewaypolicy mcp-backends-tenant-b-policy \
  -o jsonpath='{.spec.backend.mcp.authorization}' 2>/dev/null | jq -C '.' | sed 's/^/      /'

###############################################################################
# Summary
###############################################################################
banner "What just happened"
cat <<EOF
  1. Two agent identities authenticated against the SAME Dex provider
     using their unique credentials.
  2. They called the SAME AgentGateway LB but on different URL paths
     (/mcp/tenant-a vs /mcp/tenant-b). One LB, one gateway, two tenancies.
  3. Each path is bound to its own AgentgatewayPolicy with a different
     mcp.authorization CEL allowlist — that is why tenant-a saw all
     ${A_COUNT} tools while tenant-b saw only ${B_COUNT}.
  4. Each path is also bound to its own EnterpriseAgentgatewayPolicy
     with a declared per-tenant rate limit (premium=1000/min vs
     free=5/min). Live rate-limit enforcement under high concurrency is
     covered by Package 4 (Observability + Resilience).

The differentiation is enforced inside the gateway — the upstream MCP
server pod is shared. Adding a third tenant is one more block of the
same five resources.

See examples/02-multi-tenancy.md for the walkthrough with diagrams.
EOF
