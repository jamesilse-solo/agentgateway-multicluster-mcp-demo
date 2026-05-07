#!/usr/bin/env bash
# Phase 2 — Securing Agent-to-Tool Calls: MESH-01 / MESH-02 / MESH-03
# Usage: KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase2-Securing-Tool-Calls/validate.sh
# Full narrative lives in validate.md alongside this script.
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
AGW_NS="${AGW_NS:-agentgateway-system}"
DEBUG_NS="${DEBUG_NS:-debug}"

# Colors / helpers
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
pause() { echo -e "\n  ${B}── press ENTER to continue ──${N}"; read -rp "" _; echo ""; }
step()  { echo -e "\n ${M}━━━ $* ━━━${N}\n"; }
show()  { echo -e "  ${C}\$ $*${N}"; }
ok()    { echo -e "  ${G}✅  $*${N}"; }
warn()  { echo -e "  ${Y}⚠️   $*${N}"; }
note()  { echo -e "\n  ${Y}📋  $*${N}"; }

echo -e "\n${M}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   Phase 2 — Securing Agent-to-Tool Calls                 ║${N}"
echo -e "${M}║   MESH-01 · MESH-02 · MESH-03                             ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                     ║${N}"
echo -e "${M}╚══════════════════════════════════════════════════════════╝${N}"
echo -e "  → Goal: prove ambient mesh secures agent-to-tool calls with no app changes."
echo -e "  → Net cluster change: none (policy in MESH-02 is created and deleted)."
pause

NETSHOOT=$(${KC} -n "${DEBUG_NS}" get pod -l app=netshoot -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "${NETSHOOT}" ]] && warn "No netshoot pod in ${DEBUG_NS} — traffic-side checks will be skipped."
MCP_URL="http://mcp-server-everything.${AGW_NS}.svc.cluster.local"

###############################################################################
# MESH-01 — Zero-Friction Tool Onboarding
###############################################################################
step "MESH-01 — Zero-Friction Tool Onboarding"
show "${KC} get ns ${AGW_NS} --show-labels | grep dataplane-mode"
${KC} get ns "${AGW_NS}" --show-labels | grep "dataplane-mode" \
  && ok "Namespace is ambient-enrolled" \
  || warn "Ambient label missing — see validate.md prerequisites"
note "One label enrols every pod in the namespace — application pods are unchanged."
pause

show "${KC} -n ${AGW_NS} get pod -l app=mcp-server-everything (containers)"
${KC} -n "${AGW_NS}" get pod -l app=mcp-server-everything \
  -o jsonpath='{range .items[0].spec.containers[*]}    {.name}{"\n"}{end}' || warn "Pod not found"
note "Container set matches the application Deployment — ztunnel runs as a per-node DaemonSet."
pause

show "${KC} -n istio-system get pods -l app=ztunnel -o wide"
${KC} -n istio-system get pods -l app=ztunnel -o wide
note "ztunnel runs as a per-node DaemonSet, intercepting all TCP for ambient pods."
pause

if [[ -n "${NETSHOOT}" ]]; then
  show "curl from netshoot → mcp-server-everything"
  ${KC} -n "${DEBUG_NS}" exec "${NETSHOOT}" -- \
    curl -s --max-time 5 "${MCP_URL}/" -o /dev/null -w "  HTTP %{http_code}\n" || true
  show "${KC} -n istio-system logs -l app=ztunnel --tail=50 | grep mcp-server"
  ${KC} -n istio-system logs -l app=ztunnel --tail=50 2>/dev/null \
    | grep "mcp-server-everything" | tail -5 || warn "No log lines yet — re-run curl above."
  note "src.identity / dst.identity SPIFFE URIs above = mTLS enforced without an app proxy."
fi
pause

###############################################################################
# MESH-02 — L4 Isolation
###############################################################################
step "MESH-02 — Agent-Specific Trust Boundaries (L4 Isolation)"
if [[ -n "${NETSHOOT}" ]]; then
  show "curl netshoot → mcp-server-everything (PRE-POLICY — expect success)"
  ${KC} -n "${DEBUG_NS}" exec "${NETSHOOT}" -- \
    curl -s --max-time 5 "${MCP_URL}/" -o /dev/null -w "  HTTP %{http_code}  (pre-policy)\n" || true
fi
pause

show "${KC} apply -f - (AuthorizationPolicy DENY debug → mcp-server-everything)"
${KC} apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: demo-deny-netshoot
  namespace: ${AGW_NS}
spec:
  selector:
    matchLabels:
      app: mcp-server-everything
  action: DENY
  rules:
  - from:
    - source:
        namespaces: ["${DEBUG_NS}"]
EOF
ok "Policy applied. Waiting 4s for XDS propagation..."
sleep 4

if [[ -n "${NETSHOOT}" ]]; then
  show "curl netshoot → mcp-server-everything (POST-POLICY — expect 000)"
  ${KC} -n "${DEBUG_NS}" exec "${NETSHOOT}" -- \
    curl -s --max-time 5 "${MCP_URL}/" -o /dev/null -w "  HTTP %{http_code}  (post-policy)\n" || true
fi

show "${KC} -n istio-system logs -l app=ztunnel --tail=30 | grep -i policy/denied"
${KC} -n istio-system logs -l app=ztunnel --tail=30 2>/dev/null \
  | grep -iE "policy|denied|reject" | tail -5 || warn "No matching lines yet."
note "ztunnel drops TCP at L4 using the source pod's SPIFFE identity."
pause

show "${KC} delete authorizationpolicy demo-deny-netshoot -n ${AGW_NS}"
${KC} delete authorizationpolicy demo-deny-netshoot -n "${AGW_NS}"
ok "Policy deleted — cluster restored."
pause

###############################################################################
# MESH-03 — Resilient Long-Running Sessions
###############################################################################
step "MESH-03 — Resilient Long-Running Sessions (rolling restart + heavy payload)"

echo -e "  ${Y}── PART A: rolling restart (two terminals required) ──${N}"
echo -e "  ${Y}TERMINAL 1: open a new terminal and run:${N}"
show "${KC} -n ${DEBUG_NS} exec ${NETSHOOT:-<netshoot-pod>} -- curl -N --max-time 120 ${MCP_URL}/sse"
echo -e "  ${Y}Leave it running, then return here and press ENTER.${N}"
pause

show "${KC} -n istio-system rollout restart daemonset/ztunnel"
${KC} -n istio-system rollout restart daemonset/ztunnel
${KC} -n istio-system rollout status daemonset/ztunnel --timeout=120s
ok "ztunnel DaemonSet rolled."
echo -e "  ${Y}Switch back to TERMINAL 1: the curl stream should still be active.${N}"
note "TCP state survives because it lives in the kernel, not the ztunnel pod."
pause

echo -e "  ${Y}── PART B: heavy payload (>10MB through HBONE tunnel) ──${N}"
if [[ -n "${NETSHOOT}" ]]; then
  show "dd 12MB → base64 → POST through ambient mesh (inside netshoot)"
  ${KC} -n "${DEBUG_NS}" exec "${NETSHOOT}" -- sh -c "
    dd if=/dev/urandom bs=1M count=12 2>/dev/null | base64 | tr -d '\n' > /tmp/p.b64
    printf '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_p\":\"' > /tmp/p.json
    cat /tmp/p.b64 >> /tmp/p.json
    printf '\"}}' >> /tmp/p.json
    rm /tmp/p.b64
    curl -s --max-time 60 -X POST -H 'Content-Type: application/json' -H 'Expect:' \
      ${MCP_URL}/ --data-binary @/tmp/p.json -o /dev/null \
      -w '  HTTP %{http_code}\n  Uploaded %{size_upload} bytes\n  Time %{time_total}s\n'
    rm /tmp/p.json
  " || warn "Payload test errored — see validate.md caveats."
  echo ""
  ${KC} -n istio-system logs -l app=ztunnel --tail=50 2>/dev/null \
    | grep "mcp-server-everything" | grep "bytes_recv" | tail -3 | sed 's/^/  /'
  note "Uploaded > 10,000,000 bytes + matching ztunnel bytes_recv = full payload through HBONE."
fi
pause

echo -e "\n${G}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 2 validation complete ✅                         ║${N}"
echo -e "${G}║                                                          ║${N}"
echo -e "${G}║   MESH-01  Zero-friction tool onboarding                 ║${N}"
echo -e "${G}║   MESH-02  L4 isolation via SPIFFE                       ║${N}"
echo -e "${G}║   MESH-03  Session survives restart + heavy payload      ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}\n"
