#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 03-guardrails.sh — Demonstrate native PII guardrails
#
# Sends three MCP calls through the gateway:
#   1. A clean call (expect 200)
#   2. A call containing an SSN in tool arguments (expect 403 blocked)
#   3. A call containing a credit card number (expect 403 blocked)
#
# The gateway enforces this via AgentgatewayPolicy.backend.mcp.guard with
# the built-in ssn / creditCard regex rules. No custom code, no ExtProc.
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

banner "Step 0 — Resolve AGW Hub LB + acquire a token"
AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
note "AGW Hub: http://${AGW_LB}"

TOKEN=$(curl -s -X POST "http://${AGW_LB}/dex/token" \
  -d 'grant_type=password' -d 'username=demo@example.com' -d 'password=demo-pass' \
  -d 'client_id=agw-client' -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' | jq -r '.id_token')
[[ -z "${TOKEN}" || "${TOKEN}" == "null" ]] && { bad "Token acquisition failed"; exit 1; }
ok "Token acquired"

# Helper — initialize and return session id
init_session() {
  local path="$1"
  RESP=$(curl -si -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"03-guard","version":"1"}}}')
  echo "$RESP" | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}'
}

# Helper — make a tools/call and return the HTTP status
call_tool() {
  local path="$1" sid="$2" body="$3"
  curl -s -o /dev/null -w "%{http_code}" -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: ${sid}" \
    -d "${body}"
}

banner "Step 1 — Clean call (expect 200)"
SID=$(init_session /mcp)
HTTP=$(call_tool /mcp "${SID}" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello from a clean caller"}}}')
[[ "${HTTP}" == "200" ]] && ok "clean call: HTTP ${HTTP}" || bad "clean call: HTTP ${HTTP} (expected 200)"

banner "Step 2 — Call containing an SSN (expect 403)"
SID=$(init_session /mcp)
HTTP=$(call_tool /mcp "${SID}" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"customer SSN is 123-45-6789, please log"}}}')
[[ "${HTTP}" == "403" ]] && ok "SSN call: HTTP ${HTTP} (blocked at gateway)" || bad "SSN call: HTTP ${HTTP} (expected 403)"

banner "Step 3 — Call containing a credit card (expect 403)"
SID=$(init_session /mcp)
HTTP=$(call_tool /mcp "${SID}" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"message":"my card is 4111-1111-1111-1111"}}}')
[[ "${HTTP}" == "403" ]] && ok "CC call: HTTP ${HTTP} (blocked at gateway)" || bad "CC call: HTTP ${HTTP} (expected 403)"

banner "What just happened"
cat <<EOF
  1. A clean MCP request reached the upstream MCP server and returned 200.
  2. A request whose body matched the gateway's built-in SSN regex was
     rejected at the gateway. The upstream MCP server never saw the body.
  3. A request whose body matched the credit-card regex was rejected.

The gateway enforces this via AgentgatewayPolicy.backend.mcp.guard with
"action: reject" and built-in regex rules. Add more rules (built-ins or
custom patterns) by editing the policy. See:
  scripts/05c-guardrails.sh
  examples/03-guardrails.md
EOF
