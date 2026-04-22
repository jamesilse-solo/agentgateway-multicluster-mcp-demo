#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# debug.sh — Non-interactive validation / smoke-test for the full demo stack
#
# Checks every component and reports PASS / FAIL / WARN without pausing.
# Run this before demo.sh to catch problems early.
#
# Usage:
#   ./scripts/debug.sh
#   CLUSTER1_CONTEXT=my-ctx1 CLUSTER2_CONTEXT=my-ctx2 ./scripts/debug.sh
###############################################################################

C1="${CLUSTER1_CONTEXT:-cluster1}"
C2="${CLUSTER2_CONTEXT:-cluster2}"
AGW_NS="${AGW_NAMESPACE:-agentgateway-system}"
DEX_NS="${DEX_NS:-dex}"
AREG_NS="agentregistry"
AREG_SVC="agentregistry-agentregistry-enterprise"

KC1="kubectl --context ${C1}"
KC2="kubectl --context ${C2}"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

PASS=0
WARN=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1"; ((PASS++)) || true; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $1"; ((WARN++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; ((FAIL++)) || true; }
section() { echo ""; echo -e "${BOLD}${CYAN}━━━ $1 ━━━${RESET}"; }

###############################################################################
# CLUSTER CONNECTIVITY
###############################################################################
section "Cluster Connectivity"

if ${KC1} get ns default --request-timeout=15s &>/dev/null; then
  pass "cluster1 (${C1}) reachable"
else
  fail "cluster1 (${C1}) not reachable — check KUBECONFIG / context name"
fi

if ${KC2} get ns default --request-timeout=15s &>/dev/null; then
  pass "cluster2 (${C2}) reachable"
else
  fail "cluster2 (${C2}) not reachable — check KUBECONFIG / context name"
fi

###############################################################################
# PODS — cluster1
###############################################################################
section "Pods — cluster1"

check_pod() {
  local ctx="$1" ns="$2" label="$3" name="$4"
  local kc="kubectl --context ${ctx}"
  local running
  running=$(${kc} get pods -n "${ns}" -l "${label}" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${running}" -ge 1 ]]; then
    pass "${name} — ${running} Running pod(s)"
  else
    local total
    total=$(${kc} get pods -n "${ns}" -l "${label}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${total}" -eq 0 ]]; then
      fail "${name} — no pods found (label: ${label})"
    else
      local status
      status=$(${kc} get pods -n "${ns}" -l "${label}" --no-headers 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ' ')
      fail "${name} — pods exist but not Running: ${status}"
    fi
  fi
}

check_pod "${C1}" "${AGW_NS}" "app.kubernetes.io/name=enterprise-agentgateway"  "AGW controller (cluster1)"
check_pod "${C1}" "${AGW_NS}" "app=ext-auth-service"                              "ExtAuth service (cluster1)"
check_pod "${C1}" "${AGW_NS}" "app=mcp-server-everything"                         "mcp-server-everything (cluster1)"
check_pod "${C1}" "${DEX_NS}" "app=dex"                                           "Dex OIDC provider (cluster1)"

# AgentRegistry (optional)
AREG_RUNNING=$(${KC1} get pods -n "${AREG_NS}" -l "app.kubernetes.io/name=agentregistry-enterprise" \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${AREG_RUNNING}" -ge 1 ]]; then
  pass "AgentRegistry Enterprise — ${AREG_RUNNING} Running pod(s)"
else
  warn "AgentRegistry Enterprise not running — run 04-areg-enterprise.sh"
fi

# ext-cache (Redis)
REDIS_RUNNING=$(${KC1} get pods -n "${AGW_NS}" --no-headers 2>/dev/null | grep ext-cache | grep Running | wc -l | tr -d ' ')
if [[ "${REDIS_RUNNING}" -ge 1 ]]; then
  pass "ext-cache (Redis) — ${REDIS_RUNNING} Running pod(s)"
else
  warn "ext-cache (Redis) not running — ExtAuth sessions may not persist"
fi

###############################################################################
# PODS — cluster2
###############################################################################
section "Pods — cluster2"

check_pod "${C2}" "${AGW_NS}" "app.kubernetes.io/name=enterprise-agentgateway"  "AGW controller (cluster2)"
check_pod "${C2}" "${AGW_NS}" "app=mcp-server-everything"                         "mcp-server-everything (cluster2)"

###############################################################################
# KUBERNETES RESOURCES — cluster1
###############################################################################
section "K8s Resources — cluster1"

check_resource() {
  local ctx="$1" ns="$2" kind="$3" name="$4"
  local kc="kubectl --context ${ctx}"
  if ${kc} get "${kind}" "${name}" -n "${ns}" &>/dev/null; then
    pass "${kind}/${name} exists"
  else
    fail "${kind}/${name} NOT found in namespace ${ns}"
  fi
}

# Gateways
check_resource "${C1}" "${AGW_NS}" "gateway" "agentgateway-hub"

# ExtAuth
check_resource "${C1}" "${AGW_NS}" "authconfig"                      "oidc-dex"
check_resource "${C1}" "${AGW_NS}" "enterpriseagentgatewaypolicy"    "oidc-extauth"
check_resource "${C1}" "${AGW_NS}" "secret"                          "oauth-dex"

# AuthConfig acceptance status
AUTH_STATE=$(${KC1} get authconfig oidc-dex -n "${AGW_NS}" \
  -o jsonpath='{.status.state}' 2>/dev/null || echo "MISSING")
if [[ "${AUTH_STATE}" == "ACCEPTED" || "${AUTH_STATE}" == "Accepted" ]]; then
  pass "AuthConfig oidc-dex status: ${AUTH_STATE}"
else
  fail "AuthConfig oidc-dex status: ${AUTH_STATE} (expected ACCEPTED)"
fi

# AgentgatewayBackends
check_resource "${C1}" "${AGW_NS}" "agentgatewaybackend" "dex-backend"
for be in mcp-backends mcp-backends-remote agent-registry-backend; do
  if ${KC1} get agentgatewaybackend "${be}" -n "${AGW_NS}" &>/dev/null; then
    pass "AgentgatewayBackend/${be} exists"
  else
    warn "AgentgatewayBackend/${be} not found — may need 06-cross-cluster-mcp.sh or 04-areg-enterprise.sh"
  fi
done

# HTTPRoutes
for rt in mcp-route mcp-route-remote areg-mcp-route; do
  if ${KC1} get httproute "${rt}" -n "${AGW_NS}" &>/dev/null; then
    pass "HTTPRoute/${rt} exists"
  else
    warn "HTTPRoute/${rt} not found"
  fi
done

# cross-cluster global label on cluster2
CC_LABEL=$(${KC2} get svc mcp-server-everything -n "${AGW_NS}" \
  -o jsonpath='{.metadata.labels.solo\.io/service-scope}' 2>/dev/null || echo "")
if [[ "${CC_LABEL}" == "global" ]]; then
  pass "mcp-server-everything (cluster2) has solo.io/service-scope=global"
else
  warn "mcp-server-everything (cluster2) missing global label — run 06-cross-cluster-mcp.sh"
fi

###############################################################################
# AGENTGATEWAY LB
###############################################################################
section "AgentGateway LB Address"

AGW_LB="${AGW_LB:-}"
if [[ -z "${AGW_LB}" ]]; then
  AGW_LB=$(${KC1} -n "${AGW_NS}" get svc agentgateway-hub \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

if [[ -n "${AGW_LB}" ]]; then
  pass "AgentGateway LB: ${AGW_LB}"
else
  fail "AgentGateway LB address not assigned — service may still be pending"
  echo ""
  echo "  Skipping HTTP-level tests (no LB address)."
  section "Summary"
  echo ""
  echo -e "  ${GREEN}PASS: ${PASS}${RESET}   ${YELLOW}WARN: ${WARN}${RESET}   ${RED}FAIL: ${FAIL}${RESET}"
  echo ""
  exit 1
fi

###############################################################################
# HTTP SMOKE TESTS
###############################################################################
section "HTTP Smoke Tests — Flow 1 (ExtAuth / Dex OIDC)"

# Unauthenticated → 302
UNAUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "http://${AGW_LB}/mcp" 2>/dev/null || echo "000")
if [[ "${UNAUTH_CODE}" == "302" ]]; then
  pass "GET /mcp (no auth) → HTTP 302 (redirect to Dex)"
elif [[ "${UNAUTH_CODE}" == "401" ]]; then
  pass "GET /mcp (no auth) → HTTP 401 (ExtAuth active)"
else
  fail "GET /mcp (no auth) → HTTP ${UNAUTH_CODE} (expected 302 or 401)"
fi

# Location header points to Dex
LOCATION=$(curl -sI --max-time 10 "http://${AGW_LB}/mcp" 2>/dev/null \
  | grep -i '^location:' | tr -d '\r' || echo "")
if echo "${LOCATION}" | grep -qi "dex"; then
  pass "Location header contains 'dex': ${LOCATION}"
elif [[ -n "${LOCATION}" ]]; then
  warn "Location header present but doesn't mention dex: ${LOCATION}"
else
  warn "No Location header returned (may be 401 not 302)"
fi

###############################################################################
# TOKEN ACQUISITION
###############################################################################
section "Token Acquisition — Dex ROPC"

# Port-forward Dex
pkill -f "port-forward.*dex.*5556" 2>/dev/null || true
sleep 1
${KC1} -n "${DEX_NS}" port-forward svc/dex 5556:5556 &>/dev/null &
PF_DEX_PID=$!

# Wait for Dex to be ready (up to 15s)
DEX_READY=false
for i in $(seq 1 15); do
  if curl -s --max-time 2 http://localhost:5556/dex/healthz 2>/dev/null | grep -q "Health"; then
    DEX_READY=true
    break
  fi
  sleep 1
done

if [[ "${DEX_READY}" == "true" ]]; then
  pass "Dex port-forward ready (localhost:5556)"
else
  fail "Dex port-forward not responding after 15s — check 'kubectl -n dex get pods'"
fi

TOKEN=""
if [[ "${DEX_READY}" == "true" ]]; then
  TOKEN_RESP=$(curl -s --max-time 10 -X POST http://localhost:5556/dex/token \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password&username=demo@example.com&password=demo-pass' \
    -d 'client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile' \
    2>/dev/null || echo '{}')

  TOKEN=$(echo "${TOKEN_RESP}" | python3 -c \
    "import sys,json; t=json.load(sys.stdin); print(t.get('access_token',''))" 2>/dev/null || echo "")

  if [[ -n "${TOKEN}" ]]; then
    pass "JWT acquired from Dex (demo@example.com)"
    # Decode payload (base64url)
    PAYLOAD=$(echo "${TOKEN}" | cut -d. -f2 | tr '_-' '/+' | \
      python3 -c "import sys,base64,json; d=sys.stdin.read().strip(); d+='='*(-len(d)%4); print(json.dumps(json.loads(base64.b64decode(d)),indent=2))" 2>/dev/null || echo "")
    EMAIL=$(echo "${PAYLOAD}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('email','<not found>'))" 2>/dev/null || echo "<parse error>")
    ISS=$(echo "${PAYLOAD}"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('iss','<not found>'))"   2>/dev/null || echo "<parse error>")
    echo "     email: ${EMAIL}"
    echo "     iss:   ${ISS}"
  else
    ERROR_DESC=$(echo "${TOKEN_RESP}" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))" 2>/dev/null || echo "${TOKEN_RESP}")
    fail "Token acquisition failed: ${ERROR_DESC}"
    if echo "${TOKEN_RESP}" | grep -q "invalid_grant\|invalidPassword\|user"; then
      echo "     Hint: check demo user email/password in Dex ConfigMap"
    fi
  fi
fi

###############################################################################
# HTTP SMOKE TESTS — Flow 2 (Bearer token → MCP session)
###############################################################################
section "HTTP Smoke Tests — Flow 2 (Bearer → MCP session)"

if [[ -n "${TOKEN}" ]]; then
  # MCP initialize
  INIT_RESP=$(curl -si --max-time 15 -X POST "http://${AGW_LB}/mcp" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"debug-check","version":"1.0"}}}' \
    2>/dev/null || echo "")

  INIT_HTTP=$(echo "${INIT_RESP}" | grep "^HTTP/" | awk '{print $2}')
  SESSION_ID=$(echo "${INIT_RESP}" | grep -i "^mcp-session-id:" | awk '{print $2}' | tr -d '\r')
  SERVER_NAME=$(echo "${INIT_RESP}" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ -n "${SESSION_ID}" ]]; then
    pass "POST /mcp (Bearer) → HTTP ${INIT_HTTP}, session established"
    pass "Mcp-Session-Id: ${SESSION_ID}"
    [[ -n "${SERVER_NAME}" ]] && pass "Backend server: ${SERVER_NAME}"
  else
    fail "POST /mcp (Bearer) → HTTP ${INIT_HTTP}, no session ID returned"
    echo "     Raw response (first 400 chars):"
    echo "${INIT_RESP}" | head -c 400
    echo ""
  fi

  # tools/list
  if [[ -n "${SESSION_ID}" ]]; then
    TOOLS_RESP=$(curl -s --max-time 15 -X POST "http://${AGW_LB}/mcp" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Mcp-Session-Id: ${SESSION_ID}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
      2>/dev/null || echo "")

    TOOL_COUNT=$(echo "${TOOLS_RESP}" | grep -o '"name":"[^"]*"' | wc -l | tr -d ' ')
    if [[ "${TOOL_COUNT}" -gt 0 ]]; then
      pass "tools/list → ${TOOL_COUNT} tool(s) returned"
      echo "${TOOLS_RESP}" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | head -6 | while read -r t; do
        echo "     - ${t}"
      done
    else
      fail "tools/list → 0 tools returned"
      echo "     Raw (first 300): $(echo "${TOOLS_RESP}" | head -c 300)"
    fi
  fi
else
  warn "Skipping Flow 2 checks (no token)"
fi

###############################################################################
# CROSS-CLUSTER ROUTE
###############################################################################
section "Cross-Cluster Route (/mcp/remote)"

# MCP requires POST — a bare GET returns 406. Use initialize to test the route.
CC_RESP=$(curl -si --max-time 15 -X POST "http://${AGW_LB}/mcp/remote" \
  ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"debug-cc","version":"1.0"}}}' \
  2>/dev/null || echo "")

CC_CODE=$(echo "${CC_RESP}" | grep "^HTTP/" | awk '{print $2}')
CC_SESSION=$(echo "${CC_RESP}" | grep -i "^mcp-session-id:" | awk '{print $2}' | tr -d '\r')
CC_SERVER=$(echo "${CC_RESP}" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

if [[ -n "${CC_SESSION}" ]]; then
  pass "POST /mcp/remote → HTTP ${CC_CODE}, session established (cross-cluster route live)"
  pass "Remote server: ${CC_SERVER}"
elif [[ "${CC_CODE}" == "302" || "${CC_CODE}" == "401" ]]; then
  warn "POST /mcp/remote → HTTP ${CC_CODE} (auth enforced on remote route — needs token)"
elif [[ "${CC_CODE}" == "404" ]]; then
  fail "POST /mcp/remote → HTTP 404 — HTTPRoute mcp-route-remote not attached to gateway"
elif [[ "${CC_CODE}" == "503" ]]; then
  fail "POST /mcp/remote → HTTP 503 — backend unreachable (check mcp-server-everything on cluster2 and solo.io/service-scope=global label)"
else
  fail "POST /mcp/remote → HTTP ${CC_CODE} (no session ID)"
  [[ -n "${CC_RESP}" ]] && echo "     Raw (first 300): $(echo "${CC_RESP}" | head -c 300)"
fi

###############################################################################
# AGENTREGISTRY (optional)
###############################################################################
section "AgentRegistry Enterprise (optional)"

if [[ "${AREG_RUNNING}" -ge 1 ]]; then
  # Port-forward AREG MCP port
  pkill -f "port-forward.*agentregistry.*31313" 2>/dev/null || true
  sleep 1
  ${KC1} -n "${AREG_NS}" port-forward "svc/${AREG_SVC}" 31313:31313 &>/dev/null &
  PF_AREG_PID=$!
  sleep 3

  AREG_TOKEN="${TOKEN:-}"
  if [[ -z "${AREG_TOKEN}" && "${DEX_READY}" == "true" ]]; then
    AREG_TOKEN=$(curl -s --max-time 10 -X POST http://localhost:5556/dex/token \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -d 'grant_type=password&username=demo@example.com&password=demo-pass' \
      -d 'client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile' \
      | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('access_token',''))" 2>/dev/null || echo "")
  fi

  AREG_INIT=$(curl -si --max-time 15 -X POST "http://localhost:31313/mcp" \
    -H "Authorization: Bearer ${AREG_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"debug-check","version":"1.0"}}}' \
    2>/dev/null || echo "")

  AREG_HTTP=$(echo "${AREG_INIT}" | grep "^HTTP/" | awk '{print $2}')
  AREG_SESSION=$(echo "${AREG_INIT}" | grep -i "^mcp-session-id:" | awk '{print $2}' | tr -d '\r')

  if [[ -n "${AREG_SESSION}" ]]; then
    pass "AgentRegistry MCP initialize → HTTP ${AREG_HTTP}, session: ${AREG_SESSION}"

    AREG_TOOLS=$(curl -s --max-time 10 -X POST "http://localhost:31313/mcp" \
      -H "Authorization: Bearer ${AREG_TOKEN}" \
      -H "Mcp-Session-Id: ${AREG_SESSION}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
      2>/dev/null || echo "")
    AREG_TOOL_COUNT=$(echo "${AREG_TOOLS}" | grep -o '"name":"[^"]*"' | wc -l | tr -d ' ')
    if [[ "${AREG_TOOL_COUNT}" -gt 0 ]]; then
      pass "AgentRegistry tools/list → ${AREG_TOOL_COUNT} tool(s)"
      echo "${AREG_TOOLS}" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | head -6 | while read -r t; do
        echo "     - ${t}"
      done
    else
      fail "AgentRegistry tools/list → 0 tools (check roleMapper CEL + token claims)"
      echo "     Hint: kubectl -n agentregistry logs deploy/${AREG_SVC} | grep -i 'role\|auth\|claim' | tail -20"
    fi
  else
    fail "AgentRegistry MCP initialize → HTTP ${AREG_HTTP} (no session ID)"
    echo "     Raw (first 300): $(echo "${AREG_INIT}" | head -c 300)"
    echo "     Hint: check roleMapper CEL expression and Dex token claims"
  fi

  kill "${PF_AREG_PID}" 2>/dev/null || true
else
  warn "AgentRegistry not running — skipping MCP session checks"
fi

###############################################################################
# CLEANUP
###############################################################################
kill "${PF_DEX_PID}" 2>/dev/null || true

###############################################################################
# SUMMARY
###############################################################################
section "Summary"
echo ""
echo -e "  ${GREEN}PASS: ${PASS}${RESET}   ${YELLOW}WARN: ${WARN}${RESET}   ${RED}FAIL: ${FAIL}${RESET}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo -e "  ${RED}${BOLD}${FAIL} failure(s) detected. Fix the issues above before running demo.sh.${RESET}"
  echo ""
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo -e "  ${YELLOW}${BOLD}All critical checks passed. ${WARN} warning(s) — optional components may be missing.${RESET}"
  echo ""
  exit 0
else
  echo -e "  ${GREEN}${BOLD}All checks passed. Ready to demo.${RESET}"
  echo ""
  exit 0
fi
