#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 03-guardrails.sh — Demonstrate tool-name guardrails (what works today)
#
# Sends three MCP calls:
#   1. A clean call to "echo"            (expect 200, isError=false)
#   2. A call to "delete_database"       (expect blocked at gateway)
#   3. A call to "admin_reset"           (expect blocked — startsWith match)
#
# These are the live guardrails available for MCP backends in Solo CRD
# v2.3.3. Body-content PII regex on MCP traffic requires the ExtProc /
# vendor-backend path — see examples/03-guardrails.md for the breakdown.
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
note "AGW Hub: http://${AGW_LB}"

TOKEN=$(curl -s -X POST "http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/token" \
  -d 'grant_type=password' -d 'username=demo' -d 'password=demo-pass' \
  -d 'client_id=agw-client' -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' | jq -r '.id_token')
[[ -z "${TOKEN}" || "${TOKEN}" == "null" ]] && { bad "Token acquisition failed"; exit 1; }
ok "Token acquired"

init_session() {
  local path="$1"
  RESP=$(curl -si -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"03-guard","version":"1"}}}')
  echo "$RESP" | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}'
}

call_tool() {
  local path="$1" sid="$2" body="$3"
  curl -s -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Session-Id: ${sid}" \
    -d "${body}" \
    | grep -o 'data:.*' | head -1 | sed 's/^data: //'
}

banner "Step 1 — Clean call to 'echo' (expect 200, no error)"
SID=$(init_session /mcp)
RESP=$(call_tool /mcp "${SID}" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}')
IS_ERR=$(echo "${RESP}" | jq -r '.result.isError // "false"')
[[ "${IS_ERR}" == "false" ]] && ok "echo call: success" || bad "echo call returned isError=${IS_ERR}"

banner "Step 2 — Call 'delete_database' (expect denied)"
SID=$(init_session /mcp)
RESP=$(call_tool /mcp "${SID}" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_database","arguments":{}}}')
ERR_MSG=$(echo "${RESP}" | jq -r '.error.message // .result.content[0].text // empty' 2>/dev/null)
if echo "${ERR_MSG}" | grep -qiE "denied|forbidden|unknown tool|tool not"; then
  ok "delete_database call: denied — \"${ERR_MSG:0:80}\""
elif echo "${RESP}" | jq -e '.result.isError == true' >/dev/null 2>&1; then
  ok "delete_database call: isError=true"
else
  bad "delete_database call may have leaked through:"
  echo "      ${RESP:0:200}"
fi

banner "Step 3 — Call 'admin_reset' (startsWith blocklist — expect denied)"
SID=$(init_session /mcp)
RESP=$(call_tool /mcp "${SID}" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"admin_reset","arguments":{}}}')
ERR_MSG=$(echo "${RESP}" | jq -r '.error.message // .result.content[0].text // empty' 2>/dev/null)
if echo "${ERR_MSG}" | grep -qiE "denied|forbidden|unknown tool|tool not"; then
  ok "admin_reset call: denied — \"${ERR_MSG:0:80}\""
elif echo "${RESP}" | jq -e '.result.isError == true' >/dev/null 2>&1; then
  ok "admin_reset call: isError=true"
else
  bad "admin_reset call may have leaked through:"
  echo "      ${RESP:0:200}"
fi

banner "What just happened"
cat <<EOF
  1. The "echo" tool is on the implicit allowlist — call succeeded.
  2. The "delete_database" tool name is on the Deny blocklist — the
     gateway rejected the call before reaching the MCP server.
  3. The "admin_*" prefix is also denied via startsWith. Same enforcement
     path.

These are the live MCP guardrails available in Solo CRD v2.3.3. Content-
level PII regex (SSN / credit-card in request bodies) for MCP traffic
requires the ExtProc / vendor-backend path — see examples/03-guardrails.md.
EOF
