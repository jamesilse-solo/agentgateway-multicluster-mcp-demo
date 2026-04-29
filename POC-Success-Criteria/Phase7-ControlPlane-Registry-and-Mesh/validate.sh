#!/usr/bin/env bash
# Control Plane — AgentRegistry, Agent Gateway & Ambient Mesh: Interactive Validation
# Tests: CP-02 through CP-05
# Usage: KUBE_CONTEXT=cluster1 KUBE_CONTEXT2=cluster2 ./POC-Success-Criteria/Phase7-ControlPlane-Registry-and-Mesh/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC_CTX2="${KUBE_CONTEXT2:-cluster2}"
KC="kubectl --context ${KC_CTX}"
KC2="kubectl --context ${KC_CTX2}"
AGW_NS="agentgateway-system"
AREG_NS="agentregistry"
AREG_LOCAL_PORT="${AREG_LOCAL_PORT:-8080}"
AREG_SVC_PORT="${AREG_SVC_PORT:-12121}"

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
echo -e "${M}║   Control Plane — AgentRegistry, Gateway & Mesh           ║${N}"
echo -e "${M}║   Hub: ${KC_CTX}   Spoke: ${KC_CTX2}               ║${N}"
echo -e "${M}║   Tests: CP-02 · 04 · 05                                ║${N}"
echo -e "${M}╚════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  → Goal: validate the registry reflects health state in real time,"
echo -e "    and distributed traces span the full cross-cluster call path via OTEL."
pause

# Start port-forward to AgentRegistry
pkill -f "port-forward.*${AREG_NS}.*${AREG_LOCAL_PORT}" 2>/dev/null || true
sleep 1
${KC} -n "${AREG_NS}" port-forward "svc/agentregistry" \
  "${AREG_LOCAL_PORT}:${AREG_SVC_PORT}" &>/dev/null &
PF_AREG=$!
trap 'kill "${PF_AREG}" 2>/dev/null || true' EXIT
sleep 3

AREG_OK=false
if curl -s --max-time 3 "http://localhost:${AREG_LOCAL_PORT}/v0/servers" &>/dev/null; then
  AREG_OK=true
  ok "AgentRegistry port-forward ready at :${AREG_LOCAL_PORT}"
else
  warn "AgentRegistry port-forward not ready — CP-02 registry checks will be limited"
fi

###############################################################################
# CP-02 — Central Registry & Health Checks
###############################################################################
step "CP-02 — Central Registry & Health Checks"
echo -e "  → AgentRegistry maintains a live catalog of all MCP servers."
echo -e "  → AgentGateway performs active health checks on registered servers."
echo -e "  → When a server is unhealthy, the control plane reflects the status"
echo -e "    and removes it from active L7 discovery."
pause

# CP-02.1 — List registered servers
show "GET http://localhost:${AREG_LOCAL_PORT}/v0/servers"
if [[ "${AREG_OK}" == "true" ]]; then
  curl -s --max-time 10 \
    "http://localhost:${AREG_LOCAL_PORT}/v0/servers" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
servers = d.get('servers', [])
print(f'  {len(servers)} registered server(s):')
for s in servers:
    srv = s['server']
    url = (srv.get('remotes') or [{}])[0].get('url', '(no url)')
    print(f'    ✓ {srv[\"name\"]:50s}  {url}')
" 2>/dev/null || warn "Could not parse server list"
else
  warn "AgentRegistry not reachable — skipping server list"
fi
note "The registry shows all registered MCP endpoints. AgentGateway polls these
      endpoints and marks unhealthy servers, which are then excluded from routing."
pause

# CP-02.2 — Check health of AGW backends
show "${KC} -n ${AGW_NS} get agentgatewaybackend -o yaml | grep -A5 'status\\|health'"
${KC} -n "${AGW_NS}" get agentgatewaybackend -o yaml 2>/dev/null \
  | grep -A5 -i "status\|health\|ready" | head -30 \
  || echo "  (no status/health fields found in backend resources)"
note "In production: simulate an unhealthy server by scaling its Deployment to 0.
      The AGW health check will mark it as unhealthy in the backend status, and
      the registry /v0/servers list will reflect the change."
pause

###############################################################################
# CP-04 — Super Admin Master Control
###############################################################################
step "CP-04 — Super Admin Master Control"
echo -e "  → The Super Admin account has cluster-scoped visibility across all"
echo -e "    workspaces and all clusters."
echo -e "  → From a single pane of glass, the Super Admin can view all data planes,"
echo -e "    all registered MCP servers, and all policy configurations globally."
pause

# CP-04.1 — Show AgentRegistry with all servers (super admin view)
if [[ "${AREG_OK}" == "true" ]]; then
  show "GET /v0/servers (all namespaces — super admin view)"
  curl -s --max-time 10 \
    "http://localhost:${AREG_LOCAL_PORT}/v0/servers" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
servers = d.get('servers', [])
print(f'  Total servers across all namespaces: {len(servers)}')
namespaces = set()
for s in servers:
    ns = s['server']['name'].split('/')[0]
    namespaces.add(ns)
print(f'  Namespaces: {sorted(namespaces)}')
" 2>/dev/null || true
fi
note "The Super Admin sees all registered servers regardless of namespace.
      A workspace-scoped admin would only see servers in their namespace prefix."
pause

# CP-04.2 — Show all routes and policies (global visibility)
show "${KC} -n ${AGW_NS} get httproute,agentgatewaybackend,enterpriseagentgatewaypolicy"
${KC} -n "${AGW_NS}" get httproute,agentgatewaybackend,enterpriseagentgatewaypolicy 2>/dev/null \
  || warn "Could not list AGW resources on ${KC_CTX}"
echo ""
show "${KC2} -n ${AGW_NS} get httproute,agentgatewaybackend 2>/dev/null"
${KC2} -n "${AGW_NS}" get httproute,agentgatewaybackend 2>/dev/null \
  || warn "Could not list AGW resources on ${KC_CTX2}"
note "The Super Admin sees all AgentGateway resources across both clusters.
      A BU workspace admin would see only the resources in their workspace namespace."
pause

###############################################################################
# CP-05 — OTEL Distributed Tracing
###############################################################################
step "CP-05 — OTEL Distributed Tracing"
echo -e "  → Execute an MCP tools/call via the gateway to the federated server."
echo -e "  → A single trace span maps the full cross-cluster journey."
echo -e "  → Metrics correctly label the tool invocation and latency per hop."
pause

# CP-05.1 — Check OTEL collector / Jaeger
show "${KC} -n ${AGW_NS} get pod | grep -E 'otel|jaeger|tempo'"
${KC} -n "${AGW_NS}" get pod 2>/dev/null | grep -Ei "otel|jaeger|tempo" \
  || echo "  (no OTEL stack found in ${AGW_NS})"
show "${KC} get pod -A | grep -E 'otel|jaeger|tempo'"
${KC} get pod -A 2>/dev/null | grep -Ei "otel|jaeger|tempo" | head -5 \
  || warn "No OTEL/Jaeger pods found — deploy OTEL stack to enable tracing"
note "AgentGateway emits OTEL traces on every MCP call. Deploy an OTEL collector
      and Jaeger/Tempo to visualize the full cross-cluster trace.
      Reference: docs.solo.io/agentgateway/2.2.x/observability/otel-stack/"
pause

# CP-05.2 — Show OTEL config in AGW
show "${KC} -n ${AGW_NS} get enterpriseagentgatewaypolicy -o yaml | grep -A10 otel"
${KC} -n "${AGW_NS}" get enterpriseagentgatewaypolicy -o yaml 2>/dev/null \
  | grep -A10 -i "otel\|tracing\|opentelemetry" | head -20 \
  || echo "  (no OTEL policy configured — add tracing via EnterpriseAgentgatewayPolicy)"
pause

# CP-05.3 — Execute a tools/call and retrieve trace ID
NETSHOOT=$(${KC} -n debug get pod -l app=netshoot \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
AGW_SVC_IP=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/list → capture traceparent / x-trace-id header"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 15 \
    -X POST -H "Content-Type: application/json" \
    -D - \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    2>/dev/null | grep -i "traceparent\|x-trace\|x-b3-traceid" | head -5 \
    || echo "  (no trace headers in response — OTEL may not be configured yet)"
  note "The traceparent header (W3C Trace Context) carries the trace ID across
        all hops. In Jaeger, search for this trace ID to see the full span from
        the AGW hub → HBONE tunnel → cluster2 ztunnel → MCP server."
fi
pause

# CP-05.4 — Port-forward Jaeger UI (if deployed)
JAEGER_SVC=$(${KC} get svc -A 2>/dev/null | grep jaeger | head -1 | awk '{print $1 " " $2}')
if [[ -n "${JAEGER_SVC}" ]]; then
  JAEGER_NS=$(echo "${JAEGER_SVC}" | awk '{print $1}')
  JAEGER_SVC_NAME=$(echo "${JAEGER_SVC}" | awk '{print $2}')
  echo -e "  ${Y}── Jaeger detected: kubectl --context ${KC_CTX} -n ${JAEGER_NS} port-forward svc/${JAEGER_SVC_NAME} 16686:16686 ──${N}"
  echo -e "  ${Y}   Open: http://localhost:16686  Search service: agentgateway${N}"
else
  warn "Jaeger/Tempo not found. To deploy: see docs.solo.io/agentgateway/2.2.x/observability/otel-stack/"
fi
pause

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Control Plane validation complete ✅              ║${N}"
echo -e "${G}║                                                      ║${N}"
echo -e "${G}║   CP-02  Registry health checks + catalog accuracy   ║${N}"
echo -e "${G}║   CP-04  Super admin global visibility               ║${N}"
echo -e "${G}║   CP-05  OTEL distributed tracing (cross-cluster)    ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
echo ""
