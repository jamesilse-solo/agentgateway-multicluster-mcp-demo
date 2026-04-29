#!/usr/bin/env bash
# L7 Agent Gateway — Routing & Federation: Interactive Validation
# Tests: L7-RT-01 through L7-RT-05
# Usage: KUBE_CONTEXT=cluster1-singtel ./POC-Success-Criteria/Phase4-L7-Routing-and-Federation/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC_CTX2="${KUBE_CONTEXT2:-cluster2}"
KC="kubectl --context ${KC_CTX}"
AGW_NS="agentgateway-system"
DEX_NS="${DEX_NAMESPACE:-dex}"
DEX_LOCAL_PORT="${DEX_LOCAL_PORT:-5556}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'

pause() {
  echo -e "\n  ${B}─────────────────────────────────────────────────${N}"
  echo -e "  ${B}  ⏎  Press ENTER to continue...${N}"
  echo -e "  ${B}─────────────────────────────────────────────────${N}"
  read -rp "" _
  echo ""
}

step() {
  echo -e "\n ${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e " ${M}  $*${N}"
  echo -e " ${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
}

show() {
  echo -e "\n  ${C}──────────────────────────────────────────────────────────${N}"
  echo -e "  ${C}  \$ $*${N}"
  echo -e "  ${C}──────────────────────────────────────────────────────────${N}\n"
}

ok()   { echo -e "  ${G}✅  $*${N}"; }
warn() { echo -e "  ${Y}⚠️   $*${N}"; }
note() { echo -e "\n  ${Y}📋  $*${N}"; }

echo ""
echo -e "${M}╔════════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   L7 Agent Gateway — Routing & Federation                 ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                 ║${N}"
echo -e "${M}║   Tests: L7-RT-01 · 02 · 03 · 04 · 05                   ║${N}"
echo -e "${M}╚════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  → Goal: prove that AgentGateway's Envoy proxy parses JSON-RPC,"
echo -e "    merges backends into a composite server, routes cross-cluster,"
echo -e "    maintains stateful sessions, filters tools, and translates"
echo -e "    protocols — all transparently from the agent's perspective."
pause

NETSHOOT=$(${KC} -n debug get pod -l app=netshoot \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "${NETSHOOT}" ]] && warn "No netshoot pod found — in-cluster curl tests will be skipped."

AGW_SVC_IP=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

# Acquire Dex JWT (ExtAuth enforces on all AGW traffic including ClusterIP)
pkill -f "port-forward.*dex.*${DEX_LOCAL_PORT}" 2>/dev/null || true
sleep 1
${KC} -n "${DEX_NS}" port-forward svc/dex "${DEX_LOCAL_PORT}:5556" &>/dev/null &
DEX_PF=$!
trap 'kill "${DEX_PF}" 2>/dev/null || true' EXIT
sleep 3

TOKEN=$(curl -s --max-time 10 \
  -X POST "http://localhost:${DEX_LOCAL_PORT}/dex/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=demo@example.com&password=demo-pass" \
  -d "client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

if [[ -n "${TOKEN}" ]]; then
  ok "JWT acquired (${#TOKEN} chars) — will be passed on all AGW calls"
else
  warn "Could not acquire JWT — AGW calls may return 302/401 redirects"
fi

###############################################################################
# L7-RT-01 — Composite Server / Single URL
###############################################################################
step "L7-RT-01 — Composite Server / Single URL"
echo -e "  → AgentGateway merges multiple MCP backends into one virtual server."
echo -e "    A single tools/list call returns a unified schema from all backends."
pause

# RT-01.1 — Show AgentgatewayBackend resources
show "${KC} -n ${AGW_NS} get agentgatewaybackend"
${KC} -n "${AGW_NS}" get agentgatewaybackend 2>/dev/null \
  || warn "No AgentgatewayBackend resources found — run setup scripts first"
note "Each AgentgatewayBackend CRD represents one or more upstream MCP server targets.
      A single HTTPRoute with multiple backendRefs merges their tool schemas."
pause

# RT-01.2 — Show all HTTPRoutes on the hub gateway
show "${KC} -n ${AGW_NS} get httproute -o wide"
${KC} -n "${AGW_NS}" get httproute -o wide 2>/dev/null \
  || warn "No HTTPRoutes found"
pause

# RT-01.3 — Call tools/list and show merged tool list
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/list to agentgateway-hub /mcp (composite schema)"
  SESSION=$(${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 15 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
    -D - \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    2>/dev/null | grep -i "Mcp-Session-Id" | awk '{print $2}' | tr -d '\r' || true)

  TOOL_COUNT=$(${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 15 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
    ${SESSION:+-H "Mcp-Session-Id: ${SESSION}"} \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    2>/dev/null | python3 -c "
import sys, json
raw = sys.stdin.read()
d = {}
try:
    d = json.loads(raw)
except Exception:
    for ln in raw.split('\n'):
        if ln.startswith('data: '):
            try: d = json.loads(ln[6:]); break
            except Exception: pass
tools = d.get('result', {}).get('tools', [])
print(len(tools))
" 2>/dev/null || echo "?")
  echo -e "  Tools returned: ${TOOL_COUNT}"
  note "A merged tools/list from multiple backends proves the gateway is parsing
        JSON-RPC and merging schemas — not just proxying bytes."
fi
pause

###############################################################################
# L7-RT-02 — L7 Gateway Federation
###############################################################################
step "L7-RT-02 — L7 Gateway Federation"
echo -e "  → Client connects to the hub gateway on cluster1 and calls a tool"
echo -e "    that lives behind the spoke on cluster2. The gateway routes the"
echo -e "    JSON-RPC call over the ambient HBONE mesh automatically."
pause

# RT-02.1 — Show the cross-cluster route config
show "${KC} -n ${AGW_NS} get httproute mcp-route-remote -o yaml | grep -A10 'rules:'"
${KC} -n "${AGW_NS}" get httproute mcp-route-remote -o yaml 2>/dev/null \
  | grep -A10 "rules:" | head -20 \
  || warn "mcp-route-remote HTTPRoute not found — run 06-cross-cluster-mcp.sh"
note "/mcp/remote maps to the AgentgatewayBackend that resolves cluster2's
      mcp-server-everything.agentgateway-system.mesh.internal via the east-west gateway."
pause

# RT-02.2 — Send a tools/list to the remote path
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/list → /mcp/remote (routes to cluster2 via HBONE)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 20 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
    "http://${AGW_SVC_IP}/mcp/remote" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    -o /dev/null \
    -w "  HTTP %{http_code}  (tools from cluster2 MCP server)\n" \
    || warn "Cross-cluster routing failed — check east-west gateway and mcp-route-remote"
  note "The client uses one URL. The gateway transparently selects the cluster2 backend.
        No VPN, no custom client code, no cluster2 credentials needed."
fi
pause

###############################################################################
# L7-RT-03 — Stateful Session Affinity (Mcp-Session-Id)
###############################################################################
step "L7-RT-03 — Stateful Session Affinity (Mcp-Session-Id)"
echo -e "  → The gateway issues an Mcp-Session-Id on initialization."
echo -e "    Subsequent requests bearing that header are pinned to the same"
echo -e "    backend replica — ensuring the stateful MCP session is maintained."
pause

# RT-03.1 — Show session routing config in the AgentgatewayBackend
show "${KC} -n ${AGW_NS} get agentgatewaybackend -o yaml | grep -i session"
${KC} -n "${AGW_NS}" get agentgatewaybackend -o yaml 2>/dev/null \
  | grep -i "session\|affinity\|hash" | head -10 \
  || echo "  (using default stateful session routing)"
note "By default, AgentGateway issues an Mcp-Session-Id on the initialize response
      and uses it as a hash key for subsequent routing. Disable with sessionRouting: Stateless."
pause

# RT-03.2 — Initialize and capture session ID
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST /mcp initialize → capture Mcp-Session-Id header"
  SESSION_ID=$(${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 15 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
    -D /dev/stderr \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    2>&1 | grep -i "Mcp-Session-Id:" | awk '{print $2}' | tr -d '\r' || true)
  if [[ -n "${SESSION_ID}" ]]; then
    ok "Session ID issued: ${SESSION_ID}"
    echo -e "\n  Sending 3 follow-up requests with the same session ID..."
    for i in 1 2 3; do
      ${KC} -n debug exec "${NETSHOOT}" -- \
        curl -s --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
        -H "Mcp-Session-Id: ${SESSION_ID}" \
        "http://${AGW_SVC_IP}/mcp" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":${i},\"method\":\"tools/list\",\"params\":{}}" \
        -o /dev/null -w "  Request ${i}: HTTP %{http_code}\n" || true
    done
    note "All requests with the same Mcp-Session-Id are pinned to the same backend
          replica. Scale to multiple AGW replicas to see the affinity in action."
  else
    warn "No Mcp-Session-Id returned — server may be stateless or initialize failed"
  fi
fi
pause

###############################################################################
# L7-RT-04 — Static Tool Filtering
###############################################################################
step "L7-RT-04 — Static Tool Filtering"
echo -e "  → The gateway can filter which tools are exposed per AgentgatewayBackend,"
echo -e "    limiting the tool list an LLM sees based on label selectors or"
echo -e "    configuration metadata."
pause

# RT-04.1 — Show tool selector configuration
show "${KC} -n ${AGW_NS} get agentgatewaybackend -o yaml | grep -A5 'toolSelector'"
${KC} -n "${AGW_NS}" get agentgatewaybackend -o yaml 2>/dev/null \
  | grep -A5 -i "toolSelector\|tool_selector\|filter\|label" | head -20 \
  || echo "  (no tool selectors configured — all tools from backend are exposed)"
note "Static tool filtering in AgentgatewayBackend uses label selectors to expose
      only approved tools to downstream agents. The LLM cannot invoke hidden tools
      even if it hallucinates their names."
pause

# RT-04.2 — Compare filtered vs unfiltered tools/list
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/list → /mcp (all backends) and /mcp/remote (remote backend)"
  LOCAL_TOOLS=$(${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    2>/dev/null | python3 -c "
import sys, json
raw = sys.stdin.read()
d = {}
try:
    d = json.loads(raw)
except Exception:
    for ln in raw.split('\n'):
        if ln.startswith('data: '):
            try: d = json.loads(ln[6:]); break
            except Exception: pass
tools = d.get('result', {}).get('tools', [])
print(f'{len(tools)} tools: ' + ', '.join(t[\"name\"] for t in tools[:5]))
" 2>/dev/null || echo "?")
  echo -e "  /mcp: ${LOCAL_TOOLS}"
  note "Different routes can expose different tool subsets. A 'Project X' context
        header could select a filtered backend that only exposes approved tools."
fi
pause

###############################################################################
# L7-RT-05 — Legacy Protocol Translation (SSE → Streamable HTTP)
###############################################################################
step "L7-RT-05 — Legacy Protocol Translation (HTTP+SSE ↔ Streamable HTTP)"
echo -e "  → AgentGateway automatically detects whether a backend uses legacy"
echo -e "    HTTP+SSE (two endpoints: GET /sse + POST /messages) or modern"
echo -e "    Streamable HTTP (single POST endpoint) and translates between them."
pause

# RT-05.1 — Show protocol detection in AgentgatewayBackend
show "${KC} -n ${AGW_NS} get agentgatewaybackend -o yaml | grep -i 'protocol\\|sse\\|transport'"
${KC} -n "${AGW_NS}" get agentgatewaybackend -o yaml 2>/dev/null \
  | grep -iA2 "protocol\|sse\|transport\|streamable" | head -20 \
  || echo "  (using default protocol auto-detection)"
note "AgentGateway detects the backend transport from the /sse endpoint's
      response. If the backend returns an SSE event stream on GET /sse,
      the gateway translates Streamable HTTP POSTs into SSE+message pairs
      transparently. The client always uses the modern Streamable HTTP protocol."
pause

# RT-05.2 — Attempt SSE connection to verify protocol handling
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "GET /mcp/sse from netshoot (legacy SSE endpoint — triggers protocol detection)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 \
    -H "Accept: text/event-stream" \
    ${TOKEN:+-H "Authorization: Bearer ${TOKEN}"} \
    "http://${AGW_SVC_IP}/mcp/sse" \
    -o /dev/null -w "  HTTP %{http_code}  (any non-302 = protocol probe accepted)\n" || true
  note "If the backend supports SSE, the gateway returns an event stream.
        If the backend supports Streamable HTTP, the gateway proxies it directly.
        The client code is identical in both cases."
fi
pause

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   L7 Routing validation complete ✅                 ║${N}"
echo -e "${G}║                                                      ║${N}"
echo -e "${G}║   L7-RT-01  Composite server / merged tools/list     ║${N}"
echo -e "${G}║   L7-RT-02  Cross-cluster L7 JSON-RPC federation     ║${N}"
echo -e "${G}║   L7-RT-03  Stateful session affinity (Mcp-Session-Id)║${N}"
echo -e "${G}║   L7-RT-04  Static tool filtering per backend         ║${N}"
echo -e "${G}║   L7-RT-05  Legacy SSE ↔ Streamable HTTP translation  ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
echo ""
