#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# demo.sh — MCP Demo: AgentGateway + Dex OIDC + Cross-Cluster MCP
#
# Interactive step-by-step demo script. Each section pauses for the presenter
# to confirm before proceeding. Run from the repo root.
#
# Pre-conditions:
#   - 01-install.sh + 02-configure.sh ran on both clusters
#   - 03-dex.sh ran (Dex deployed on cluster1)
#   - 05-extauth.sh ran (ExtAuth wired to Dex on cluster1)
#   - 06-cross-cluster-mcp.sh ran (cross-cluster HTTPRoute configured)
#
# Usage:
#   export AGENTGATEWAY_LICENSE_KEY=<key>
#   ./scripts/demo.sh
###############################################################################

# ─── Config ──────────────────────────────────────────────────────────────────
C1="${CLUSTER1_CONTEXT:-cluster1}"
C2="${CLUSTER2_CONTEXT:-cluster2}"
AGW_NS="${AGW_NAMESPACE:-agentgateway-system}"
DEX_NS="${DEX_NS:-dex}"
AGW_LB="${AGW_LB:-}"

# ─── Colours ─────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
KC1="kubectl --context ${C1}"
KC2="kubectl --context ${C2}"

banner()  { echo ""; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"; echo -e "${BOLD}${CYAN}  $1${RESET}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"; echo ""; }
step()    { echo -e "${BOLD}${GREEN}▶  $1${RESET}"; }
info()    { echo -e "   ${CYAN}$1${RESET}"; }
warn()    { echo -e "   ${YELLOW}⚠  $1${RESET}"; }
ok()      { echo -e "   ${GREEN}✓  $1${RESET}"; }
cmd()     { echo -e "   ${BOLD}\$ $1${RESET}"; }
pause()   {
  echo ""
  echo -e "   ${YELLOW}Press ENTER to continue...${RESET}"
  read -r
}
run() {
  echo -e "   ${BOLD}\$ $*${RESET}"
  eval "$@"
  echo ""
}

###############################################################################
# RESOLVE AGW LB
###############################################################################
if [[ -z "${AGW_LB}" ]]; then
  AGW_LB=$(${KC1} -n "${AGW_NS}" get svc agentgateway-hub \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
fi

if [[ -z "${AGW_LB}" ]]; then
  echo "ERROR: Could not resolve AgentGateway LB address. Set AGW_LB=<hostname> and retry."
  exit 1
fi

###############################################################################
# SECTION 0 — PRE-FLIGHT
###############################################################################
banner "Pre-flight: Verifying all components"

step "AgentGateway Hub (cluster1)"
run "${KC1} get pods -n ${AGW_NS} --no-headers | grep -v '^$'"

step "Dex OIDC provider (cluster1)"
run "${KC1} get pods -n ${DEX_NS} --no-headers"

step "ExtAuth resources"
run "${KC1} -n ${AGW_NS} get authconfig/oidc-dex enterpriseagentgatewaypolicy/oidc-extauth --no-headers 2>/dev/null || true"

step "MCP server — cluster1 (local)"
run "${KC1} -n ${AGW_NS} get deploy/mcp-server-everything --no-headers"

step "MCP server — cluster2 (remote)"
run "${KC2} -n ${AGW_NS} get deploy/mcp-server-everything --no-headers"

step "Cross-cluster ServiceEntry (mesh.internal propagation)"
run "${KC1} get serviceentry -n istio-system 2>/dev/null | grep mcp || echo '  (none — run 06-cross-cluster-mcp.sh)'"

info "AgentGateway LB: ${AGW_LB}"
info "Demo URL:        http://${AGW_LB}/mcp"
echo ""

pause

###############################################################################
# SECTION 1 — OIDC AUTH (BROWSER FLOW)
###############################################################################
banner "Act 1 — OIDC Auth: AgentGateway + Dex"

info "AgentGateway is protecting all MCP traffic with OIDC via Dex."
info "An unauthenticated request to /mcp gets redirected to the Dex login page."
echo ""

step "Unauthenticated request → expect HTTP 302"
run "curl -s -o /dev/null -w 'HTTP %{http_code}\\n' http://${AGW_LB}/mcp"

step "Location header — where the redirect goes"
REDIRECT=$(curl -sI "http://${AGW_LB}/mcp" 2>/dev/null | grep -i "^location:" | tr -d '\r')
echo "   ${REDIRECT}"
echo ""
info "The redirect URL contains: client_id=agw-client, response_type=code"
info "In a browser this opens the Dex login page."
echo ""

pause

###############################################################################
# SECTION 2 — OIDC AUTH (MCP CLIENT BEARER TOKEN FLOW + FULL MCP SESSION)
###############################################################################
banner "Act 2 — Authenticated MCP Session via Dex"

info "MCP API clients (AI agents, SDKs) use the password grant to get a JWT"
info "from Dex and pass it as a Bearer token. AgentGateway's ExtAuth validates"
info "the JWT, then proxies the MCP session to the backend."
echo ""

step "Port-forwarding Dex locally for token acquisition"
pkill -f "port-forward.*dex.*5556" 2>/dev/null || true
sleep 1
${KC1} -n "${DEX_NS}" port-forward svc/dex 5556:5556 &
PF_DEX_PID=$!
sleep 4

step "Step 1 — Acquire JWT from Dex (ROPC / password grant)"
info "  POST http://localhost:5556/dex/token"
info "  grant_type=password  client_id=agw-client  user=demo@example.com"
TOKEN=$(curl -s -X POST http://localhost:5556/dex/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password&username=demo@example.com&password=demo-pass' \
  -d 'client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile' \
  | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('access_token','ERROR'))" 2>/dev/null)

if [[ "${TOKEN}" == "ERROR" || -z "${TOKEN}" ]]; then
  warn "Token acquisition failed — check Dex is running and port-forward is up"
  TOKEN=""
else
  ok "JWT acquired  iss=http://dex.dex.svc.cluster.local:5556/dex"
  echo "   ${TOKEN:0:72}..."
fi
echo ""

if [[ -n "${TOKEN}" ]]; then
  step "Step 2 — Initialize MCP session through AgentGateway (Bearer token)"
  info "  POST http://${AGW_LB}/mcp   Authorization: Bearer <jwt>"
  info "  method: initialize   protocolVersion: 2024-11-05"
  echo ""

  INIT_RESPONSE=$(curl -si -X POST "http://${AGW_LB}/mcp" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-demo","version":"1.0"}}}' \
    2>/dev/null)

  SESSION_ID=$(echo "${INIT_RESPONSE}" | grep -i "^mcp-session-id:" | awk '{print $2}' | tr -d '\r')
  INIT_STATUS=$(echo "${INIT_RESPONSE}" | grep "^HTTP/" | awk '{print $2}')
  SERVER_NAME=$(echo "${INIT_RESPONSE}" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
  SERVER_VER=$(echo "${INIT_RESPONSE}"  | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)

  if [[ -n "${SESSION_ID}" ]]; then
    ok "HTTP ${INIT_STATUS} — MCP session established"
    ok "Mcp-Session-Id: ${SESSION_ID}"
    ok "Server: ${SERVER_NAME} v${SERVER_VER}"
  else
    warn "HTTP ${INIT_STATUS} — no session ID returned; check ExtAuth and backend"
  fi
  echo ""

  if [[ -n "${SESSION_ID}" ]]; then
    step "Step 3 — List MCP tools (authenticated session)"
    info "  POST http://${AGW_LB}/mcp   Mcp-Session-Id: ${SESSION_ID}"
    info "  method: tools/list"
    echo ""

    TOOLS_RESPONSE=$(curl -s -X POST "http://${AGW_LB}/mcp" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Mcp-Session-Id: ${SESSION_ID}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
      2>/dev/null)

    TOOL_NAMES=$(echo "${TOOLS_RESPONSE}" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | head -8)

    if [[ -n "${TOOL_NAMES}" ]]; then
      ok "Tools available on authenticated session:"
      while IFS= read -r tool; do
        echo "      - ${tool}"
      done <<< "${TOOL_NAMES}"
    else
      warn "No tools returned — check backend MCP server is running"
    fi
    echo ""
  fi
fi

pause

###############################################################################
# SECTION 3 — CROSS-CLUSTER MCP VIA AMBIENT MESH
###############################################################################
banner "Act 3 — Cross-Cluster MCP via Istio Ambient Mesh"

info "AgentGateway on cluster1 (hub) routes /mcp/remote to cluster2's"
info "mcp-server-everything via the ambient east-west gateway."
info "No sidecar injection, no VPN tunnel — just ztunnel HBONE."
echo ""

step "Dedicated cross-cluster route (always hits cluster2)"
REMOTE_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
  "http://${AGW_LB}/mcp/remote" 2>/dev/null)
echo "   GET /mcp/remote → HTTP ${REMOTE_CODE}"
if [[ "${REMOTE_CODE}" == "400" || "${REMOTE_CODE}" == "200" ]]; then
  ok "Cross-cluster route is live"
else
  warn "Unexpected HTTP ${REMOTE_CODE} — check mcp-backends-remote backend"
fi
echo ""

pause

step "FAILOVER DEMO: scaling cluster1 MCP server to 0 replicas"
info "Watch: /mcp/remote keeps working because cluster2 still has the pod."
run "${KC1} -n ${AGW_NS} scale deploy/mcp-server-everything --replicas=0"
run "${KC1} -n ${AGW_NS} get pods -l app=mcp-server-everything --no-headers"

info "cluster2 pod is still running:"
run "${KC2} -n ${AGW_NS} get pods -l app=mcp-server-everything --no-headers"
echo ""

step "Cross-cluster route still serves (cluster1 has 0 local pods)"
FAILOVER_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
  "http://${AGW_LB}/mcp/remote" 2>/dev/null)
echo "   GET /mcp/remote → HTTP ${FAILOVER_CODE}"
if [[ "${FAILOVER_CODE}" == "400" || "${FAILOVER_CODE}" == "200" ]]; then
  ok "Traffic served from cluster2 via ambient east-west gateway"
else
  warn "HTTP ${FAILOVER_CODE} — may need a moment for endpoint update"
fi
echo ""

info "Traffic path:"
info "  curl → AGW Hub (cluster1) → ztunnel (HBONE/15008) → EW Gateway → ztunnel (cluster2) → mcp-server-everything"
echo ""

pause

step "Restoring cluster1 MCP server"
run "${KC1} -n ${AGW_NS} scale deploy/mcp-server-everything --replicas=1"
run "${KC1} -n ${AGW_NS} rollout status deploy/mcp-server-everything --timeout=60s"
echo ""

###############################################################################
# SECTION 4 — AGENTREGISTRY CATALOG
###############################################################################
banner "Act 4 — AgentRegistry Enterprise: MCP Catalog"

AREG_POD=$(${KC1} -n agentregistry get pod -l app.kubernetes.io/name=agentregistry-enterprise \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "${AREG_POD}" ]]; then
  warn "AgentRegistry Enterprise is not running (run 04-areg-enterprise.sh first)"
  warn "Skipping this section."
  SKIP_AREG=true
else
  SKIP_AREG=false
  ok "AgentRegistry pod: ${AREG_POD}"
  echo ""

  info "AgentRegistry Enterprise stores a catalog of MCP servers."
  info "Seeded with 363 community MCP server definitions on startup."
  info "AgentGateway discovers and proxies backends registered here."
  echo ""

  step "Port-forwarding AgentRegistry (UI on 8080, MCP on 31313)"
  pkill -f "port-forward.*agentregistry.*8080" 2>/dev/null || true
  pkill -f "port-forward.*agentregistry.*31313" 2>/dev/null || true
  sleep 1
  # Helm chart names the service agentregistry-agentregistry-enterprise
  AREG_SVC="agentregistry-agentregistry-enterprise"
  ${KC1} -n agentregistry port-forward "svc/${AREG_SVC}" 8080:8080 &
  PF_AREG_UI_PID=$!
  ${KC1} -n agentregistry port-forward "svc/${AREG_SVC}" 31313:31313 &
  PF_AREG_MCP_PID=$!
  PF_AREG_PID="${PF_AREG_UI_PID}"
  sleep 3

  ok "AgentRegistry UI open at: http://localhost:8080"
  ok "AgentRegistry MCP endpoint: http://localhost:31313/mcp"
  echo ""

  step "Querying AgentRegistry catalog via its MCP endpoint (port 31313)"
  info "  POST http://localhost:31313/mcp   method: initialize"
  info "  Auth: Bearer token from Dex (AREG enforces OIDC — same demo user)"

  AREG_INIT_TOKEN="${TOKEN:-}"
  if [[ -z "${AREG_INIT_TOKEN}" ]]; then
    # Re-acquire token if Act 2 was skipped or token expired
    AREG_INIT_TOKEN=$(curl -s -X POST http://localhost:5556/dex/token \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -d 'grant_type=password&username=demo@example.com&password=demo-pass' \
      -d 'client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile' \
      | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('access_token',''))" 2>/dev/null || echo "")
  fi

  AREG_INIT=$(curl -si -X POST "http://localhost:31313/mcp" \
    -H "Authorization: Bearer ${AREG_INIT_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-demo","version":"1.0"}}}' \
    2>/dev/null)

  AREG_SESSION=$(echo "${AREG_INIT}" | grep -i "^mcp-session-id:" | awk '{print $2}' | tr -d '\r')
  AREG_STATUS=$(echo "${AREG_INIT}" | grep "^HTTP/" | awk '{print $2}')

  if [[ -n "${AREG_SESSION}" ]]; then
    ok "HTTP ${AREG_STATUS} — AgentRegistry MCP session: ${AREG_SESSION}"
    echo ""

    step "Listing AgentRegistry MCP tools"
    AREG_TOOLS=$(curl -s -X POST "http://localhost:31313/mcp" \
      -H "Authorization: Bearer ${AREG_INIT_TOKEN}" \
      -H "Mcp-Session-Id: ${AREG_SESSION}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
      2>/dev/null)

    AREG_TOOL_NAMES=$(echo "${AREG_TOOLS}" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | head -8)
    if [[ -n "${AREG_TOOL_NAMES}" ]]; then
      ok "AgentRegistry MCP tools:"
      while IFS= read -r tool; do
        echo "      - ${tool}"
      done <<< "${AREG_TOOL_NAMES}"
    else
      warn "No tools returned — check AREG RBAC (roleMapper CEL) and token claims"
    fi
  else
    warn "HTTP ${AREG_STATUS} — could not establish AREG MCP session"
    info "Verify: kubectl -n agentregistry logs deploy/agentregistry-agentregistry-enterprise | tail -20"
  fi
  echo ""

  pause

  step "AgentRegistry accessible via AgentGateway hub at /mcp/registry"
  info "  Any MCP client that authenticates with Dex can reach the catalog"
  info "  through the same hub gateway — no separate auth config needed."

  if [[ -n "${TOKEN:-}" ]]; then
    AREG_AGW_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      "http://${AGW_LB}/mcp/registry" 2>/dev/null)
    echo "   GET http://${AGW_LB}/mcp/registry → HTTP ${AREG_AGW_CODE}"
    if [[ "${AREG_AGW_CODE}" == "200" || "${AREG_AGW_CODE}" == "400" ]]; then
      ok "AgentRegistry reachable through AGW hub (auth enforced by Dex ExtAuth)"
    else
      warn "HTTP ${AREG_AGW_CODE} — check areg-mcp-route HTTPRoute status"
    fi
  fi
  echo ""
fi

pause

###############################################################################
# SUMMARY
###############################################################################
banner "Demo Summary"

info "What we showed:"
echo ""
echo "   1. Dex OIDC protecting MCP endpoints on AgentGateway"
echo "      - Unauthenticated → HTTP 302 → Dex login page"
echo "      - JWT Bearer token → MCP session established, tools listed"
echo "      - Full MCP initialize + tools/list through authenticated gateway"
echo ""
echo "   2. Cross-cluster MCP via Istio Ambient Mesh"
echo "      - /mcp/remote always routes to cluster2 via .mesh.internal"
echo "      - Failover: scale cluster1 to 0 → cluster2 serves seamlessly"
echo "      - HBONE tunnel over port 15008, no sidecars, no VPN"
echo ""
echo "   3. AgentRegistry Enterprise — MCP server catalog"
echo "      - 363 community MCP servers seeded on startup"
echo "      - Catalog accessible via AGW hub at /mcp/registry (auth enforced)"
echo "      - Solo differentiator: registry-driven backend discovery"
echo ""
echo "   4. AgentGateway as the unified AI traffic control plane"
echo "      - Single hub controls auth, routing, and discovery for both clusters"
echo "      - Waypoint-based architecture: only Solo, not upstream Istio"
echo ""

info "Endpoints:"
echo "   MCP (local cluster1):   http://${AGW_LB}/mcp"
echo "   MCP (remote cluster2):  http://${AGW_LB}/mcp/remote"
echo "   AgentRegistry catalog:  http://${AGW_LB}/mcp/registry"
echo "   Dex OIDC (internal):    http://dex.dex.svc.cluster.local:5556/dex"
echo ""
info "Demo credentials:"
echo "   User:    demo@example.com / ${DEX_USER_PASSWORD:-demo-pass}"
echo "   Client:  agw-client / agw-client-secret"
echo ""

# Cleanup port-forwards
kill "${PF_DEX_PID}" 2>/dev/null || true
if [[ "${SKIP_AREG:-true}" == "false" ]]; then
  kill "${PF_AREG_UI_PID}" 2>/dev/null || true
  kill "${PF_AREG_MCP_PID}" 2>/dev/null || true
fi

echo -e "${GREEN}${BOLD}Demo complete.${RESET}"
echo ""
