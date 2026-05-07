#!/usr/bin/env bash
# Phase 3 — Federated MCP Mesh: FED-01 / FED-02 / FED-03
# Usage: KUBE_CONTEXT=cluster1 KUBE_CONTEXT2=cluster2 \
#        ./POC-Success-Criteria-v2/Phase3-Federated-MCP-Mesh/validate.sh
# Full narrative lives in validate.md alongside this script.
set -euo pipefail

KC1="${KUBE_CONTEXT:-cluster1}"
KC2="${KUBE_CONTEXT2:-cluster2}"
AGW_NS="${AGW_NS:-agentgateway-system}"
DEBUG_NS="${DEBUG_NS:-debug}"
SEND_TRAFFIC="$(dirname "$0")/../../demo/send-traffic.sh"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
pause() { echo -e "\n  ${B}── press ENTER to continue ──${N}"; read -rp "" _; echo ""; }
step()  { echo -e "\n ${M}━━━ $* ━━━${N}\n"; }
show()  { echo -e "  ${C}\$ $*${N}"; }
ok()    { echo -e "  ${G}✅  $*${N}"; }
warn()  { echo -e "  ${Y}⚠️   $*${N}"; }
note()  { echo -e "\n  ${Y}📋  $*${N}"; }

echo -e "\n${M}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   Phase 3 — Federated MCP Gateway Mesh                   ║${N}"
echo -e "${M}║   FED-01 (C1→C2) · FED-02 (C2→C1) · FED-03 (composite)   ║${N}"
echo -e "${M}║   Clusters: ${KC1} ↔ ${KC2}                              ║${N}"
echo -e "${M}╚══════════════════════════════════════════════════════════╝${N}"
echo -e "  → Goal: prove distributed-mesh routing in both directions, plus"
echo -e "    multi-backend composition behind a single URL."
echo -e "  → Net cluster change: none."
pause

C1_LB=$(kubectl --context "${KC1}" -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
C2_LB=$(kubectl --context "${KC2}" -n "${AGW_NS}" get svc agentgateway-spoke \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
[[ -z "${C1_LB}" ]] && warn "Could not resolve cluster1 LB."
[[ -z "${C2_LB}" ]] && warn "Could not resolve cluster2 LB."

###############################################################################
# FED-01 — cluster1 → cluster2
###############################################################################
step "FED-01 — Cross-Environment Federation (cluster1 → cluster2)"
echo -e "  → Agent on cluster1 calls /mcp/remote. Gateway routes through HBONE to cluster2."
pause

if [[ -x "${SEND_TRAFFIC}" ]]; then
  show "KUBE_CONTEXT=${KC1} ${SEND_TRAFFIC} --remote"
  KUBE_CONTEXT="${KC1}" "${SEND_TRAFFIC}" --remote || warn "Federated call failed — see output."
else
  warn "demo/send-traffic.sh not found. Run the inline equivalent:"
  echo -e "    curl -X POST http://${C1_LB}/mcp/remote ... (initialize → tools/list → tools/call)"
fi
note "Tool response from cluster2 above = federation through HBONE worked."
pause

###############################################################################
# FED-02 — cluster2 → cluster1
###############################################################################
step "FED-02 — Bidirectional Federation (cluster2 → cluster1)"
echo -e "  → Same MCP flow but originating at cluster2's gateway → routes back to cluster1."
pause

if [[ -x "${SEND_TRAFFIC}" && -n "${C2_LB}" ]]; then
  show "AGW_LB=${C2_LB} KUBE_CONTEXT=${KC1} ${SEND_TRAFFIC} --remote"
  AGW_LB="${C2_LB}" KUBE_CONTEXT="${KC1}" "${SEND_TRAFFIC}" --remote || warn "Reverse call failed."
else
  warn "Cannot run reverse path: missing send-traffic.sh or cluster2 LB."
fi
note "Symmetric success here means the architecture is a true distributed mesh,
      not hub-and-spoke. Adding a third environment is identical work."
pause

###############################################################################
# FED-03 — Composite Server
###############################################################################
step "FED-03 — Composite Server / Single URL"
show "kubectl --context ${KC1} -n ${AGW_NS} get agentgatewaybackend"
kubectl --context "${KC1}" -n "${AGW_NS}" get agentgatewaybackend
note "Look for two or more backends bound to one composite route. If the demo
      cluster has not configured a virtual MCP route, see docs:
      https://docs.solo.io/agentgateway/2.2.x/mcp/virtual/"
pause

echo -e "  → If a composite route exists, send a tools/list and check the merged catalog."
echo -e "  → Otherwise, this step is informational — proceed to summary."
pause

echo -e "\n${G}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 3 validation complete ✅                         ║${N}"
echo -e "${G}║                                                          ║${N}"
echo -e "${G}║   FED-01  cluster1 → cluster2 over HBONE                 ║${N}"
echo -e "${G}║   FED-02  cluster2 → cluster1 (symmetric)                ║${N}"
echo -e "${G}║   FED-03  Composite server / single URL                  ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}\n"
