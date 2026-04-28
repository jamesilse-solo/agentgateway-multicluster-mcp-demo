#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# portforward.sh — Set up all port-forwards for the Singtel demo
#
# Starts port-forwards in the background for:
#   1. AgentRegistry UI        → http://localhost:8080
#   2. AgentGateway Enterprise UI → http://localhost:9978
#   3. AgentGateway MCP endpoint  → prints external LB address (no port-forward needed)
#
# Usage:
#   ./demo/portforward.sh
#   KUBE_CONTEXT=cluster1-singtel ./demo/portforward.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1-singtel}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
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

hdr "Singtel Demo — Port-Forward Setup"
info "Cluster context: ${KUBE_CONTEXT}"
echo ""

###############################################################################
# 0. Clean up any existing port-forwards for our ports
###############################################################################
pkill -f "port-forward.*agentregistry.*8080"    2>/dev/null || true
pkill -f "port-forward.*enterprise-agentgateway.*9978" 2>/dev/null || true
pkill -f "port-forward.*enterprise-agentgateway.*9093" 2>/dev/null || true
sleep 1

###############################################################################
# 1. AgentRegistry UI  →  8080:12121
###############################################################################
hdr "1. AgentRegistry UI"

${KC} -n "${AREG_NAMESPACE}" port-forward svc/agentregistry 8080:12121 &>/dev/null &
PF_AREG=$!
echo -e "  Started (PID ${PF_AREG}), waiting for readiness..."

for i in $(seq 1 15); do
  if curl -s --max-time 2 "http://localhost:8080/v0/servers" &>/dev/null; then
    ok "AgentRegistry UI ready — http://localhost:8080"
    break
  fi
  [[ ${i} -eq 15 ]] && { fail "AgentRegistry UI not responding after 15s"; }
  sleep 1
done

###############################################################################
# 2. AgentGateway Enterprise UI  →  9978 (fallback: 9093)
###############################################################################
hdr "2. AgentGateway Enterprise UI"

# Try primary port 9978 first
${KC} -n "${AGW_NAMESPACE}" port-forward svc/enterprise-agentgateway 9978:9978 &>/dev/null &
PF_AGW_UI=$!
echo -e "  Trying port 9978 (PID ${PF_AGW_UI})..."

AGWUI_PORT=""
for i in $(seq 1 8); do
  if curl -s --max-time 2 "http://localhost:9978" &>/dev/null; then
    AGWUI_PORT="9978"
    ok "AgentGateway Enterprise UI ready — http://localhost:9978"
    break
  fi
  sleep 1
done

# Fallback: try 9093
if [[ -z "${AGWUI_PORT}" ]]; then
  kill "${PF_AGW_UI}" 2>/dev/null || true
  sleep 1
  ${KC} -n "${AGW_NAMESPACE}" port-forward svc/enterprise-agentgateway 9093:9093 &>/dev/null &
  PF_AGW_UI=$!
  echo -e "  Port 9978 did not respond — trying 9093 (PID ${PF_AGW_UI})..."

  for i in $(seq 1 8); do
    if curl -s --max-time 2 "http://localhost:9093" &>/dev/null; then
      AGWUI_PORT="9093"
      ok "AgentGateway Enterprise UI ready — http://localhost:9093"
      break
    fi
    sleep 1
  done
fi

if [[ -z "${AGWUI_PORT}" ]]; then
  warn "AgentGateway Enterprise UI did not respond on 9978 or 9093."
  warn "Check: ${KC} -n ${AGW_NAMESPACE} get svc enterprise-agentgateway"
  AGWUI_PORT="9978 (may not be responding)"
fi

###############################################################################
# 3. AgentGateway MCP endpoint — external LB (no port-forward needed)
###############################################################################
hdr "3. AgentGateway MCP Endpoint"

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -n "${AGW_LB}" ]]; then
  ok "AgentGateway LB: ${AGW_LB}"
  info "MCP endpoint:  http://${AGW_LB}/mcp"
  info "Remote route:  http://${AGW_LB}/mcp/remote"
  info "Registry MCP:  http://${AGW_LB}/mcp/registry"
else
  warn "Could not resolve AgentGateway LB."
  warn "Check: ${KC} -n ${AGW_NAMESPACE} get svc agentgateway-hub"
fi

###############################################################################
# 4. Summary
###############################################################################
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║  Demo URLs                                               ║${RESET}"
echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════╣${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  AgentRegistry UI     →  ${GREEN}http://localhost:8080${RESET}           ${BOLD}${CYAN}║${RESET}"
echo -e "${BOLD}${CYAN}║${RESET}  AgentGateway UI      →  ${GREEN}http://localhost:${AGWUI_PORT}${RESET}  ${BOLD}${CYAN}║${RESET}"
if [[ -n "${AGW_LB}" ]]; then
echo -e "${BOLD}${CYAN}║${RESET}  AGW MCP endpoint     →  ${GREEN}http://${AGW_LB}/mcp${RESET}"
fi
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${YELLOW}Press Ctrl-C to stop all port-forwards.${RESET}"
echo ""

# Keep the script alive so port-forwards stay up
trap 'echo ""; echo "Stopping port-forwards..."; kill "${PF_AREG}" "${PF_AGW_UI}" 2>/dev/null || true' EXIT INT TERM
wait
