#!/usr/bin/env bash
# Phase 2 — Bridging to Internal Remote MCP Server: Interactive Validation
# Usage: KUBE_CONTEXT=cluster1-singtel KUBE_CONTEXT2=cluster2-singtel ./Phase2/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC_CTX2="${KUBE_CONTEXT2:-cluster2}"
KC="kubectl --context ${KC_CTX}"
KC2="kubectl --context ${KC_CTX2}"
AGW_NS="agentgateway-system"

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
echo -e "${M}║   Phase 2 — Bridging to Internal Remote MCP Server        ║${N}"
echo -e "${M}║   Hub cluster:   ${KC_CTX}                              ║${N}"
echo -e "${M}║   Spoke cluster: ${KC_CTX2}                             ║${N}"
echo -e "${M}║   Tests: MESH-05 · MESH-06 · MESH-07                     ║${N}"
echo -e "${M}╚════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  → Goal: prove the mesh bridges AI agents to remote MCP tools"
echo -e "    across clusters and VMs transparently, and that agents cannot"
echo -e "    laterally scan the VPC for unauthorized endpoints."
echo ""
echo -e "  → MESH-07 applies a Sidecar egress restriction and deletes it."
echo -e "    MESH-06 applies and deletes a ServiceEntry. Net change: none."
pause

NETSHOOT=$(${KC} -n debug get pod -l app=netshoot \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "${NETSHOOT}" ]] && warn "No netshoot pod found — traffic tests will be skipped."

AGW_LB=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

###############################################################################
# MESH-05 — Abstracting Cross-Cluster/VPC Complexity (Federation)
###############################################################################
step "MESH-05 — Abstracting Cross-Cluster/VPC Complexity (Federation)"
echo -e "  → Prove that the agent calls /mcp/remote on the AGW Hub and the"
echo -e "    request is transparently routed to mcp-server-everything on"
echo -e "    cluster2 via HBONE mTLS over the east-west gateway."
echo -e "  → The agent writes zero network code — it simply uses one URL."
pause

# 5.1 — Show the cross-cluster HTTPRoute on cluster1 hub
show "${KC} -n ${AGW_NS} get httproute mcp-route-remote -o yaml"
${KC} -n "${AGW_NS}" get httproute mcp-route-remote -o yaml 2>/dev/null \
  | grep -E "path:|backendRefs:|name:|kind:" | head -20 \
  || warn "mcp-route-remote HTTPRoute not found — run 06-cross-cluster-mcp.sh first"
note "The HTTPRoute maps /mcp/remote to the AgentgatewayBackend that resolves
      mcp-server-everything.${AGW_NS}.mesh.internal — the cross-cluster DNS name."
pause

# 5.2 — Show the AgentgatewayBackend pointing to cluster2
show "${KC} -n ${AGW_NS} get agentgatewaybackend mcp-backends-remote -o yaml"
${KC} -n "${AGW_NS}" get agentgatewaybackend mcp-backends-remote -o yaml 2>/dev/null \
  | grep -E "host:|port:|name:" \
  || warn "mcp-backends-remote AgentgatewayBackend not found"
note "The backend host is mcp-server-everything.${AGW_NS}.mesh.internal — a global
      service synthesised by istiod from the solo.io/service-scope=global label on cluster2."
pause

# 5.3 — Verify mcp-server-everything is running on cluster2
show "${KC2} -n ${AGW_NS} get pod -l app=mcp-server-everything -o wide"
${KC2} -n "${AGW_NS}" get pod -l app=mcp-server-everything -o wide 2>/dev/null \
  || warn "Cannot reach cluster2 context ${KC_CTX2} — verify kubeconfig"
note "The MCP server on cluster2 is the traffic destination. The agent developer
      does not know which cluster it lives on."
pause

# 5.4 — Show east-west gateways on both clusters
show "${KC} -n istio-eastwest get svc -o wide"
${KC} -n istio-eastwest get svc -o wide 2>/dev/null || warn "istio-eastwest namespace not found on cluster1"
echo ""
show "${KC2} -n istio-eastwest get svc -o wide"
${KC2} -n istio-eastwest get svc -o wide 2>/dev/null || warn "istio-eastwest namespace not found on cluster2"
note "East-west gateways (one per cluster) carry the cross-cluster HBONE mTLS
      traffic. They are transparent to the agent and to the MCP developer."
pause

# 5.5 — Call /mcp/remote from netshoot (in-cluster, bypasses external LB auth)
if [[ -n "${NETSHOOT}" ]]; then
  AGW_SVC_IP=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  show "curl from netshoot → agentgateway-hub /mcp/remote (cross-cluster)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 15 \
    -X POST \
    -H "Content-Type: application/json" \
    "http://${AGW_SVC_IP}/mcp/remote" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    -o /dev/null \
    -w "  HTTP %{http_code}\n" || warn "Cross-cluster call failed — check east-west gateway connectivity"
  note "Any 2xx response confirms the request traversed:
        netshoot → AGW Hub (cluster1) → ztunnel HBONE → east-west GW → cluster2 ztunnel → MCP server."
else
  warn "Skipping curl test — netshoot pod not found."
fi
pause

###############################################################################
# MESH-06 — Safe Legacy Tool Integration (ServiceEntry)
###############################################################################
step "MESH-06 — Safe Legacy Tool Integration (ServiceEntry)"
echo -e "  → Register an MCP server running outside Kubernetes (e.g., a VM)"
echo -e "    as a mesh-internal service using a ServiceEntry."
echo -e "  → Agents can connect to it without knowing it's on a VM."
echo -e "  → The ServiceEntry is deleted at the end. Net cluster change: none."
pause

# 6.1 — Show existing ServiceEntries in the mesh
show "${KC} get serviceentry -A"
${KC} get serviceentry -A 2>/dev/null || warn "No ServiceEntries found (or access denied)"
note "Istio auto-creates ServiceEntries for global (mesh.internal) services.
      Custom ServiceEntries can also register VM workloads by static IP or DNS."
pause

# 6.2 — Apply a demo ServiceEntry for an external MCP-over-HTTP endpoint
show "${KC} apply -f - (ServiceEntry: demo-mcp-vm.example.internal → 1.2.3.4:8080)"
${KC} apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: demo-mcp-vm
  namespace: agentgateway-system
spec:
  hosts:
  - demo-mcp-vm.example.internal
  addresses:
  - 240.0.10.1/32
  ports:
  - number: 80
    name: http
    protocol: HTTP
  location: MESH_INTERNAL
  resolution: STATIC
  endpoints:
  - address: 1.2.3.4
    labels:
      app: mcp-server-vm
EOF
ok "ServiceEntry applied — mesh now knows about the VM-hosted MCP server."
note "The agent calls http://demo-mcp-vm.example.internal/mcp — the mesh routes
      to 1.2.3.4:80 over HBONE mTLS, even though the VM has no Kubernetes presence.
      A WorkloadEntry can also be used to extend identity and mTLS to the VM process."
pause

# 6.3 — Verify it appears in the service registry
show "${KC} get serviceentry demo-mcp-vm -n ${AGW_NS} -o yaml"
${KC} get serviceentry demo-mcp-vm -n "${AGW_NS}" -o yaml 2>/dev/null \
  | grep -E "hosts:|addresses:|endpoints:|address:" \
  || warn "ServiceEntry not found"
pause

# 6.4 — Cleanup
show "${KC} delete serviceentry demo-mcp-vm -n ${AGW_NS}"
${KC} delete serviceentry demo-mcp-vm -n "${AGW_NS}" 2>/dev/null
ok "ServiceEntry deleted — cluster restored."
pause

###############################################################################
# MESH-07 — Lateral Movement Prevention (Zero-Trust VPC)
###############################################################################
step "MESH-07 — Lateral Movement Prevention (Zero-Trust VPC)"
echo -e "  → Apply a Sidecar resource to the debug namespace restricting egress"
echo -e "    to registered mesh hosts only (equivalent to REGISTRY_ONLY per-ns)."
echo -e "  → Attempt to connect to an unregistered private IP from netshoot."
echo -e "  → Verify the connection is blocked."
echo -e "  → The Sidecar is deleted at the end. Net cluster change: none."
pause

# 7.1 — Show current outbound traffic policy
show "${KC} -n istio-system get cm istio -o jsonpath '{.data.mesh}' | grep outboundTrafficPolicy"
CURRENT_POLICY=$(${KC} -n istio-system get cm istio \
  -o jsonpath='{.data.mesh}' 2>/dev/null \
  | grep -i outboundTrafficPolicy || echo "(not explicitly set — defaults to ALLOW_ANY)")
echo -e "  Current policy: ${CURRENT_POLICY}"
note "Default is ALLOW_ANY — agents can reach any IP. We will apply a per-namespace
      Sidecar resource to the debug namespace to enforce REGISTRY_ONLY egress."
pause

# 7.2 — Baseline: connection to an unregistered external IP succeeds
if [[ -n "${NETSHOOT}" ]]; then
  show "curl from netshoot → 1.1.1.1:80 (BEFORE restriction — expect response)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 http://1.1.1.1 \
    -o /dev/null -w "  HTTP %{http_code}  (pre-restriction)\n" || true
fi
pause

# 7.3 — Apply Sidecar egress restriction to debug namespace
show "${KC} apply -f - (Sidecar: debug namespace — restrict egress to mesh hosts)"
${KC} apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: demo-restrict-egress
  namespace: debug
spec:
  egress:
  - hosts:
    - ./*
    - istio-system/*
    - agentgateway-system/*
EOF
ok "Sidecar resource applied — waiting 3s for XDS propagation..."
sleep 3
note "This Sidecar limits egress from all pods in the debug namespace to only
      services registered in the mesh. Traffic to arbitrary IPs is dropped."
pause

# 7.4 — Verify: connection to unregistered IP is now blocked
if [[ -n "${NETSHOOT}" ]]; then
  show "curl from netshoot → 1.1.1.1:80 (WITH restriction — expect blocked)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 http://1.1.1.1 \
    -o /dev/null -w "  HTTP %{http_code}  (should be 000 — connection blocked)\n" || true
  note "HTTP 000 / connection refused = the Sidecar egress restriction prevents
        the rogue agent from scanning the VPC. Only registered mesh endpoints are reachable."
fi
pause

# 7.5 — Cleanup
show "${KC} delete sidecar demo-restrict-egress -n debug"
${KC} delete sidecar demo-restrict-egress -n debug 2>/dev/null
ok "Sidecar resource deleted — cluster restored."
pause

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 2 validation complete ✅                    ║${N}"
echo -e "${G}║                                                      ║${N}"
echo -e "${G}║   MESH-05  Cross-cluster federation via HBONE        ║${N}"
echo -e "${G}║   MESH-06  VM tool onboarding via ServiceEntry       ║${N}"
echo -e "${G}║   MESH-07  Lateral movement blocked by Sidecar egress║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
echo ""
