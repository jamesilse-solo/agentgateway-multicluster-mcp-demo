#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# portforward.sh — Set up all port-forwards for the demo
#
# Starts port-forwards in the background for:
#   1. AgentRegistry Enterprise UI     → http://localhost:8080
#      MCP server catalog, discovery, traffic logs.
#      Demo auth enabled — log in with any credentials.
#
#   2. AgentGateway Enterprise UI      → http://localhost:4000
#      Routes, backends, auth policies, rate limits, guardrails.
#      Control-plane governance view (solo-enterprise-ui).
#
#   3. Gloo Mesh Enterprise UI         → http://localhost:8090
#      Cross-cluster federation, ambient mesh topology,
#      east-west gateway health, cluster registration.
#
#   4. AgentGateway MCP endpoints      → prints external LB addresses
#
# Usage:
#   ./demo/portforward.sh
#   KUBE_CONTEXT=cluster1-singtel ./demo/portforward.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
GM_NAMESPACE="${GM_NAMESPACE:-gloo-mesh}"
AREG_SVC="${AREG_SVC:-agentregistry-agentregistry-enterprise}"
AGW_MGMT_SVC="${AGW_MGMT_SVC:-solo-enterprise-ui}"
KC="kubectl --context ${KUBE_CONTEXT}"

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✓  $1${RESET}"; }
info() { echo -e "  ${CYAN}$1${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠  $1${RESET}"; }
fail() { echo -e "  ${RED}✗  $1${RESET}"; }
hdr()  { echo ""; echo -e "${BOLD}${CYAN}══  $1${RESET}"; echo ""; }

hdr "AgentGateway Demo — Port-Forward Setup"
info "Cluster context: ${KUBE_CONTEXT}"
echo ""

###############################################################################
# 0. Clean up any existing port-forwards on our ports
###############################################################################
pkill -f "port-forward.*agentregistry.*8080"   2>/dev/null || true
pkill -f "port-forward.*solo-enterprise-ui.*4000" 2>/dev/null || true
pkill -f "port-forward.*gloo-mesh-ui.*8090"    2>/dev/null || true
sleep 1

###############################################################################
# 1. AgentRegistry Enterprise UI  →  8080:8080
###############################################################################
hdr "1. AgentRegistry Enterprise UI"

${KC} -n "${AREG_NAMESPACE}" port-forward "svc/${AREG_SVC}" 8080:8080 &>/dev/null &
PF_AREG=$!
echo -e "  Started (PID ${PF_AREG}), waiting for readiness..."

AREG_OK=false
for i in $(seq 1 20); do
  if curl -s --max-time 2 "http://localhost:8080/v0/servers" &>/dev/null; then
    ok "AgentRegistry Enterprise UI ready — http://localhost:8080"
    AREG_OK=true
    break
  fi
  sleep 1
done
[[ "${AREG_OK}" == "false" ]] && warn "AgentRegistry UI not responding — check: ${KC} -n ${AREG_NAMESPACE} get pod"

###############################################################################
# 2. AgentGateway Enterprise UI  →  4000:80
###############################################################################
hdr "2. AgentGateway Enterprise UI"

${KC} -n "${AGW_NAMESPACE}" port-forward "svc/${AGW_MGMT_SVC}" 4000:80 &>/dev/null &
PF_AGW_UI=$!
echo -e "  Started (PID ${PF_AGW_UI}), waiting for readiness..."

AGW_UI_OK=false
for i in $(seq 1 20); do
  if curl -s --max-time 2 "http://localhost:4000" &>/dev/null; then
    ok "AgentGateway Enterprise UI ready — http://localhost:4000"
    AGW_UI_OK=true
    break
  fi
  sleep 1
done
[[ "${AGW_UI_OK}" == "false" ]] && warn "AgentGateway UI not responding — check: ${KC} -n ${AGW_NAMESPACE} get pod -l app=solo-enterprise-ui"

###############################################################################
# 3. Gloo Mesh Enterprise UI  →  8090:8090
###############################################################################
hdr "3. Gloo Mesh Enterprise UI"

${KC} -n "${GM_NAMESPACE}" port-forward svc/gloo-mesh-ui 8090:8090 &>/dev/null &
PF_GME=$!
echo -e "  Started (PID ${PF_GME}), waiting for readiness..."

GME_OK=false
for i in $(seq 1 15); do
  if curl -s --max-time 2 "http://localhost:8090" &>/dev/null; then
    ok "Gloo Mesh Enterprise UI ready — http://localhost:8090"
    GME_OK=true
    break
  fi
  sleep 1
done
[[ "${GME_OK}" == "false" ]] && warn "Gloo Mesh UI not responding — check: ${KC} -n ${GM_NAMESPACE} get pod -l app=gloo-mesh-ui"

###############################################################################
# 4. AgentGateway MCP endpoints — external LBs (no port-forward needed)
###############################################################################
hdr "4. AgentGateway MCP Endpoints"

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
AGW_LB2=$(kubectl --context "${KUBE_CONTEXT/cluster1/cluster2}" -n "${AGW_NAMESPACE}" \
  get svc agentgateway-spoke \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -n "${AGW_LB}" ]]; then
  ok "Cluster 1 AGW: ${AGW_LB}"
  info "  /mcp          → local MCP server (cluster 1)"
  info "  /mcp/remote   → federated MCP server (cluster 2 via HBONE)"
  info "  /mcp/registry → AgentRegistry catalog"
else
  warn "Could not resolve cluster 1 AGW LB"
fi

if [[ -n "${AGW_LB2}" ]]; then
  ok "Cluster 2 AGW: ${AGW_LB2}"
  info "  /mcp          → local MCP server (cluster 2)"
  info "  /mcp/remote   → federated MCP server (cluster 1 via HBONE)"
else
  warn "Could not resolve cluster 2 AGW LB"
fi

###############################################################################
# 5. Summary
###############################################################################
echo ""
echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║  Demo URLs                                                        ║${RESET}"
echo -e "${BOLD}${CYAN}╠═══════════════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  AgentRegistry UI         →  ${GREEN}http://localhost:8080${RESET}             ${BOLD}${CYAN}║${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  AgentGateway Enterprise  →  ${GREEN}http://localhost:4000${RESET}             ${BOLD}${CYAN}║${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  Gloo Mesh UI             →  ${GREEN}http://localhost:8090${RESET}             ${BOLD}${CYAN}║${RESET}"
if [[ -n "${AGW_LB}" ]]; then
echo -e "${BOLD}${CYAN}║${RESET}  Cluster 1 /mcp           →  ${GREEN}http://${AGW_LB}/mcp${RESET}"
fi
if [[ -n "${AGW_LB2}" ]]; then
echo -e "${BOLD}${CYAN}║${RESET}  Cluster 2 /mcp           →  ${GREEN}http://${AGW_LB2}/mcp${RESET}"
fi
echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${YELLOW}Press Ctrl-C to stop all port-forwards.${RESET}"
echo ""

trap 'echo ""; echo "Stopping port-forwards..."; kill "${PF_AREG}" "${PF_AGW_UI}" "${PF_GME}" 2>/dev/null || true' EXIT INT TERM
wait
