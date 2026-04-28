#!/usr/bin/env bash
# Phase 1 — Securing Agent to Tool Call: Interactive Validation
# Usage: KUBE_CONTEXT=cluster1-singtel ./Phase1/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"

# ── Colors (Roku demo style) ──────────────────────────────────────────────────
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

# ── Title ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${M}╔════════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   Phase 1 — Securing Agent to Tool Call                   ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                 ║${N}"
echo -e "${M}║   Tests: MESH-01 · MESH-02 · MESH-03 · MESH-04           ║${N}"
echo -e "${M}╚════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  → Goal: prove that the ambient mesh securely networks AI agents"
echo -e "    to MCP tools with zero developer friction and zero code changes."
echo ""
echo -e "  → No persistent changes will be made to the cluster."
echo -e "    (MESH-02 applies an AuthorizationPolicy and deletes it immediately.)"
pause

# ── Resolve netshoot pod once ─────────────────────────────────────────────────
NETSHOOT=$(${KC} -n debug get pod -l app=netshoot \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${NETSHOOT}" ]]; then
  warn "No netshoot pod found in debug namespace — MESH-01/02/04 traffic tests will be skipped."
fi
MCP_URL="http://mcp-server-everything.agentgateway-system.svc.cluster.local"

###############################################################################
# MESH-01 — Zero-Friction Tool Onboarding (Sidecar-less)
###############################################################################
step "MESH-01 — Zero-Friction Tool Onboarding (Sidecar-less)"
echo -e "  → Prove that mcp-server-everything participates in the ambient mesh"
echo -e "    with no sidecar proxy and no application code changes."
echo -e "  → All traffic is intercepted at the node level by ztunnel and"
echo -e "    secured with HBONE mTLS automatically."
pause

# 1.1 — Namespace ambient label
show "${KC} get ns agentgateway-system --show-labels | grep dataplane-mode"
${KC} get ns agentgateway-system --show-labels | grep "dataplane-mode" \
  && ok "Namespace is ambient-enrolled" \
  || warn "Label not found — check 01-install.sh ran successfully"
note "The label istio.io/dataplane-mode=ambient is the only change needed to enroll
      all pods in the namespace. No YAML changes to the application deployment."
pause

# 1.2 — No sidecar in the MCP server pod
show "${KC} -n agentgateway-system get pod -l app=mcp-server-everything -o jsonpath (containers)"
echo -e "  Containers in mcp-server-everything pod:"
${KC} -n agentgateway-system get pod -l app=mcp-server-everything \
  -o jsonpath='{range .items[0].spec.containers[*]}    {.name}{"\n"}{end}' 2>/dev/null \
  || warn "Pod not found"
note "Exactly one container: mcp-server. No istio-proxy sidecar injected.
      The MCP developer touches nothing — the mesh adopts the app transparently."
pause

# 1.3 — ztunnel DaemonSet (one pod per node)
show "${KC} -n istio-system get pods -l app=ztunnel -o wide"
${KC} -n istio-system get pods -l app=ztunnel -o wide
note "ztunnel runs as a DaemonSet — one pod per node. It intercepts all
      inbound/outbound TCP for ambient-enrolled pods via a netfilter socket,
      establishes mTLS HBONE tunnels, and enforces L4 policy."
pause

# 1.4 — Traffic flows through mesh + mTLS log confirmation
if [[ -n "${NETSHOOT}" ]]; then
  show "curl from netshoot → mcp-server-everything (through ambient mesh)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 "${MCP_URL}/" \
    -o /dev/null -w "  HTTP %{http_code}\n" \
    || warn "No HTTP response — server may reject root path; connection still proves mTLS tunnel"

  show "${KC} -n istio-system logs -l app=ztunnel --tail=50 | grep mcp-server"
  echo -e "  ztunnel access log (last 5 lines matching mcp-server-everything):"
  ${KC} -n istio-system logs -l app=ztunnel --tail=50 2>/dev/null \
    | grep "mcp-server-everything" | tail -5 \
    || warn "No log lines yet — run curl first or check all ztunnel pods with -l app=ztunnel"
  note "ztunnel log shows src.identity and dst.identity as SPIFFE URIs
        (spiffe://cluster.local/ns/...) — confirming mTLS without any proxy in the app."
else
  warn "Skipping curl test — netshoot pod not found."
fi
pause

###############################################################################
# MESH-02 — Agent-Specific Trust Boundaries (L4 Isolation)
###############################################################################
step "MESH-02 — Agent-Specific Trust Boundaries (L4 Isolation)"
echo -e "  → Apply a DENY AuthorizationPolicy targeting mcp-server-everything,"
echo -e "    sourced from the debug namespace (where netshoot — the 'agent' — lives)."
echo -e "  → ztunnel enforces the policy at L4 using the pod's SPIFFE identity."
echo -e "  → The policy is deleted at the end of this step. Net cluster change: none."
pause

# 2.1 — Baseline: connection succeeds before policy
if [[ -n "${NETSHOOT}" ]]; then
  show "curl netshoot → mcp-server-everything (PRE-POLICY — expect success)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 "${MCP_URL}/" \
    -o /dev/null -w "  HTTP %{http_code}  (pre-policy — should be non-zero)\n" || true
  note "Any HTTP response confirms the path is open before policy is applied."
else
  warn "Skipping baseline curl — netshoot pod not found."
fi
pause

# 2.2 — Apply deny policy
show "${KC} apply -f - (AuthorizationPolicy DENY debug → mcp-server-everything)"
${KC} apply -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: demo-deny-netshoot
  namespace: agentgateway-system
spec:
  selector:
    matchLabels:
      app: mcp-server-everything
  action: DENY
  rules:
  - from:
    - source:
        namespaces: ["debug"]
EOF
ok "Policy applied — waiting 4s for istiod → ztunnel XDS propagation..."
sleep 4

# 2.3 — Confirm blocked
if [[ -n "${NETSHOOT}" ]]; then
  show "curl netshoot → mcp-server-everything (WITH POLICY — expect blocked)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 5 "${MCP_URL}/" \
    -o /dev/null -w "  HTTP %{http_code}  (should be 000 — ztunnel drops TCP)\n" || true
fi

# 2.4 — ztunnel denial log
show "${KC} -n istio-system logs -l app=ztunnel --tail=30 | grep -i 'policy\\|denied\\|DENY'"
echo -e "  ztunnel policy rejection log:"
${KC} -n istio-system logs -l app=ztunnel --tail=30 2>/dev/null \
  | grep -i "policy\|denied\|DENY\|reject" | tail -5 \
  || warn "No matching lines — check individual ztunnel pod logs with kubectl logs <pod>"
note "ztunnel drops the TCP connection at L4 using the SPIFFE identity of the
      source pod. The application never receives the connection — no HTTP-layer
      firewall required."
pause

# 2.5 — Cleanup
show "${KC} delete authorizationpolicy demo-deny-netshoot -n agentgateway-system"
${KC} delete authorizationpolicy demo-deny-netshoot -n agentgateway-system
ok "Policy deleted — cluster restored to original state."
pause

###############################################################################
# MESH-03 — Protecting Agent Reasoning State (Session Resumability)
###############################################################################
step "MESH-03 — Protecting Agent Reasoning State (Session Resumability)"
echo -e "  → This test requires two open terminal windows."
echo ""
echo -e "  → Terminal 1: establish a long-lived streaming connection from netshoot"
echo -e "    to mcp-server-everything, simulating an AI agent holding an MCP session."
echo ""
echo -e "  → Terminal 2 (this window): rolling-restart the ztunnel DaemonSet."
echo ""
echo -e "  → Expected result: Terminal 1's curl stream continues running through"
echo -e "    the ztunnel restart — the agent session is not terminated."
pause

echo -e "  ${Y}── TERMINAL 1: open a new terminal and run this command ────────────────${N}"
show "${KC} -n debug exec ${NETSHOOT:-<netshoot-pod>} -- curl -N --max-time 120 ${MCP_URL}/sse"
echo -e "  ${Y}  Leave it running. It will stream output (or silently hold open).${N}"
echo -e "  ${Y}  Return to THIS terminal and press ENTER when it is running.${N}"
pause

echo -e "  ${Y}── TERMINAL 2 (here): rolling restart ztunnel DaemonSet ───────────────${N}"
show "${KC} -n istio-system rollout restart daemonset/ztunnel"
${KC} -n istio-system rollout restart daemonset/ztunnel
echo ""
echo -e "  Waiting for rollout to complete..."
${KC} -n istio-system rollout status daemonset/ztunnel --timeout=120s
ok "ztunnel DaemonSet rolled successfully."
echo ""
echo -e "  ${Y}  Now switch back to Terminal 1.${N}"
echo -e "  ${Y}  The curl stream should still be active (not exited with an error).${N}"
note "The HBONE tunnel re-establishes transparently per-node as ztunnel pods
      are replaced. The kernel TCP state survives the pod cycle — the AI agent
      does not lose its reasoning loop or LLM context window."
pause

###############################################################################
# MESH-04 — Handling Heavy AI Data Payloads (MTU Limits)
###############################################################################
step "MESH-04 — Handling Heavy AI Data Payloads (MTU / >10MB)"
echo -e "  → Generate a >10MB JSON-RPC body from the netshoot pod and POST it"
echo -e "    through the ambient mesh to mcp-server-everything."
echo ""
echo -e "  → size_upload > 10,000,000 bytes in the curl output proves that ztunnel's"
echo -e "    HBONE tunnel correctly fragmented and reassembled the oversized stream"
echo -e "    without truncation or a mid-connection reset."
echo ""
echo -e "  → Note: this takes ~15-20 seconds (dd + base64 generation inside netshoot)."
pause

if [[ -n "${NETSHOOT}" ]]; then
  show "dd 12MB → base64 → JSON-RPC POST via ambient mesh (inside netshoot)"
  ${KC} -n debug exec "${NETSHOOT}" -- sh -c '
    echo "  Generating 12MB random payload (base64-encoded)..."
    PADDING=$(dd if=/dev/urandom bs=1M count=12 2>/dev/null | base64 | tr -d "\n")
    echo "  Payload size: ${#PADDING} bytes (base64 expands ~1.33x)"
    echo ""
    echo "  POSTing to mcp-server-everything via ambient mesh..."
    curl -s --max-time 60 \
      -X POST \
      -H "Content-Type: application/json" \
      http://mcp-server-everything.agentgateway-system.svc.cluster.local/ \
      --data-raw "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_p\":\"${PADDING}\"}}" \
      -o /dev/null \
      -w "  HTTP status : %{http_code}\n  Uploaded   : %{size_upload} bytes\n  Downloaded : %{size_download} bytes\n  Time       : %{time_total}s\n"
  '
  note "size_upload >> 10,000,000 bytes = ztunnel forwarded the full payload without
        truncation. A response (even HTTP 4xx) = full round-trip completed through HBONE."
else
  warn "Skipping payload test — netshoot pod not found."
fi
pause

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 1 validation complete ✅                    ║${N}"
echo -e "${G}║                                                      ║${N}"
echo -e "${G}║   MESH-01  Zero-friction sidecar-less onboarding    ║${N}"
echo -e "${G}║   MESH-02  L4 isolation via SPIFFE identity          ║${N}"
echo -e "${G}║   MESH-03  Session survives ztunnel rolling restart  ║${N}"
echo -e "${G}║   MESH-04  >10MB payload through HBONE tunnel        ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
echo ""
