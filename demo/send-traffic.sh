#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# send-traffic.sh — Simulate an AI agent calling MCP through AgentGateway
#
# Demonstrates the full MCP flow:
#   1. Acquire JWT from Dex (password grant)
#   2. Initialize MCP session through AgentGateway
#   3. List available tools
#   4. Call a tool (echo)
#
# Flags:
#   --remote    Route through /mcp/remote (cluster2 cross-cluster MCP server)
#   --no-auth   Skip Dex token (anonymous / no-auth mode)
#
# Usage:
#   ./demo/send-traffic.sh
#   ./demo/send-traffic.sh --remote
#   KUBE_CONTEXT=cluster1-singtel ./demo/send-traffic.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1-singtel}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
KC="kubectl --context ${KUBE_CONTEXT}"

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
PURPLE='\033[0;35m'
RESET='\033[0m'

banner() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $1${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo ""
}
step()  { echo -e "${BOLD}${PURPLE}▶  $1${RESET}"; }
info()  { echo -e "   ${CYAN}$1${RESET}"; }
ok()    { echo -e "   ${GREEN}✓  $1${RESET}"; }
warn()  { echo -e "   ${YELLOW}⚠  $1${RESET}"; }
fail()  { echo -e "   ${RED}✗  $1${RESET}"; }
cmd()   { echo -e "   ${BOLD}\$ $1${RESET}"; }

###############################################################################
# Parse flags
###############################################################################
REMOTE=false
NO_AUTH=false
for arg in "$@"; do
  case "${arg}" in
    --remote)  REMOTE=true  ;;
    --no-auth) NO_AUTH=true ;;
  esac
done

MCP_PATH="/mcp"
if [[ "${REMOTE}" == "true" ]]; then
  MCP_PATH="/mcp/remote"
fi

###############################################################################
# Resolve AGW LB
###############################################################################
if [[ -z "${AGW_LB:-}" ]]; then
  AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

if [[ -z "${AGW_LB}" ]]; then
  fail "Could not resolve AgentGateway LB. Set AGW_LB=<hostname> and retry."
  exit 1
fi

if [[ "${REMOTE}" == "true" ]]; then
  banner "MCP Agent Traffic — Cross-Cluster (/mcp/remote)"
  info "Route: agent → AGW Hub → HBONE → cluster2 → mcp-server-everything"
else
  banner "MCP Agent Traffic — Local (/mcp)"
  info "Route: agent → AGW Hub → mcp-server-everything (cluster1)"
fi

info "AgentGateway LB: ${AGW_LB}"
info "MCP path:        ${MCP_PATH}"
echo ""

###############################################################################
# Step 1 — Acquire JWT from Dex
###############################################################################
TOKEN=""
if [[ "${NO_AUTH}" == "false" ]]; then
  step "Step 1 — Acquire JWT from Dex (password grant)"
  info "  Port-forwarding Dex locally on :5556..."
  pkill -f "port-forward.*dex.*5556" 2>/dev/null || true
  sleep 1
  ${KC} -n "${DEX_NAMESPACE}" port-forward svc/dex 5556:5556 &>/dev/null &
  PF_DEX=$!
  trap 'kill "${PF_DEX}" 2>/dev/null || true' EXIT

  for i in $(seq 1 12); do
    if curl -s --max-time 2 "http://localhost:5556/dex/.well-known/openid-configuration" &>/dev/null; then
      break
    fi
    [[ ${i} -eq 12 ]] && { fail "Dex not reachable on :5556 after 12s"; exit 1; }
    sleep 1
  done

  cmd "POST http://localhost:5556/dex/token  grant_type=password  user=demo@example.com"
  TOKEN=$(curl -s -X POST http://localhost:5556/dex/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password&username=demo@example.com&password=demo-pass' \
    -d 'client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile' \
    | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('access_token',''))" 2>/dev/null || echo "")

  if [[ -z "${TOKEN}" ]]; then
    warn "Token acquisition failed — check Dex is running"
    warn "Continuing without auth token..."
  else
    ok "JWT acquired"
    info "  ${TOKEN:0:72}..."
  fi
  echo ""
else
  info "Skipping auth (--no-auth flag set)"
  echo ""
fi

###############################################################################
# Build common curl headers
###############################################################################
AUTH_HEADER=""
if [[ -n "${TOKEN}" ]]; then
  AUTH_HEADER="-H \"Authorization: Bearer ${TOKEN}\""
fi

###############################################################################
# Step 2 — Initialize MCP session
###############################################################################
step "Step 2 — Initialize MCP session"
cmd "POST http://${AGW_LB}${MCP_PATH}   method: initialize"
echo ""

INIT_RESPONSE=$(curl -si -X POST "http://${AGW_LB}${MCP_PATH}" \
  ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"singtel-demo-agent","version":"1.0"}}}' \
  2>/dev/null)

SESSION_ID=$(echo "${INIT_RESPONSE}" | grep -i "^mcp-session-id:" | awk '{print $2}' | tr -d '\r')
INIT_STATUS=$(echo "${INIT_RESPONSE}" | grep "^HTTP/" | awk '{print $2}')
SERVER_NAME=$(echo "${INIT_RESPONSE}" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
SERVER_VER=$(echo "${INIT_RESPONSE}"  | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [[ -n "${SESSION_ID}" ]]; then
  ok "HTTP ${INIT_STATUS} — MCP session established"
  ok "Mcp-Session-Id: ${SESSION_ID}"
  [[ -n "${SERVER_NAME}" ]] && ok "Server: ${SERVER_NAME} ${SERVER_VER:+v${SERVER_VER}}"
else
  if [[ "${INIT_STATUS}" == "302" || "${INIT_STATUS}" == "401" ]]; then
    fail "HTTP ${INIT_STATUS} — Auth required. Is the Bearer token valid?"
  else
    warn "HTTP ${INIT_STATUS} — No Mcp-Session-Id returned"
    warn "Raw response snippet:"
    echo "${INIT_RESPONSE}" | head -20 | sed 's/^/   /'
  fi
  echo ""
  exit 1
fi
echo ""

###############################################################################
# Step 3 — List tools
###############################################################################
step "Step 3 — List MCP tools"
cmd "POST http://${AGW_LB}${MCP_PATH}   method: tools/list   session: ${SESSION_ID:0:16}..."
echo ""

TOOLS_RESPONSE=$(curl -s -X POST "http://${AGW_LB}${MCP_PATH}" \
  ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  2>/dev/null)

TOOL_NAMES=$(echo "${TOOLS_RESPONSE}" | python3 -c \
  "import sys,json; d=json.loads(sys.stdin.read().strip().lstrip('data: ')); \
   tools=d.get('result',{}).get('tools',[]); \
   [print('      -',t['name']) for t in tools[:10]]" 2>/dev/null || \
  echo "${TOOLS_RESPONSE}" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | head -10 | sed 's/^/      - /')

if [[ -n "${TOOL_NAMES}" ]]; then
  ok "Tools available on ${MCP_PATH}:"
  echo "${TOOL_NAMES}"
else
  warn "No tools returned — raw response:"
  echo "${TOOLS_RESPONSE}" | head -5 | sed 's/^/   /'
fi
echo ""

###############################################################################
# Step 4 — Call a tool (echo)
###############################################################################
step "Step 4 — Call tool: echo"
cmd "POST http://${AGW_LB}${MCP_PATH}   method: tools/call   tool: echo"
echo ""

CALL_RESPONSE=$(curl -s -X POST "http://${AGW_LB}${MCP_PATH}" \
  ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"Hello from Singtel AgentGateway demo"}}}' \
  2>/dev/null)

CALL_TEXT=$(echo "${CALL_RESPONSE}" | python3 -c \
  "import sys,json; raw=sys.stdin.read().strip().lstrip('data: '); \
   d=json.loads(raw); \
   content=d.get('result',{}).get('content',[]); \
   [print(c.get('text','')) for c in content if c.get('type')=='text']" 2>/dev/null || \
  echo "${CALL_RESPONSE}" | grep -o '"text":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [[ -n "${CALL_TEXT}" ]]; then
  ok "Tool response:"
  echo "   ${CALL_TEXT}"
else
  warn "No text content in tool response:"
  echo "${CALL_RESPONSE}" | head -3 | sed 's/^/   /'
fi
echo ""

###############################################################################
# Summary
###############################################################################
if [[ "${REMOTE}" == "true" ]]; then
  echo -e "${GREEN}${BOLD}✓  Cross-cluster MCP call complete.${RESET}"
  echo -e "   Request traveled: agent → AGW Hub (cluster1) → HBONE → cluster2 → tool"
else
  echo -e "${GREEN}${BOLD}✓  Local MCP call complete.${RESET}"
  echo -e "   Request traveled: agent → AGW Hub (cluster1) → mcp-server-everything"
fi
echo ""
