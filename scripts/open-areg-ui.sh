#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# open-areg-ui.sh — Open AgentRegistry UI from your local machine
#
# The AREG UI does an OIDC redirect to Dex on an internal cluster hostname
# (dex.dex.svc.cluster.local). Two port-forwards + an /etc/hosts entry are
# required for the browser to follow that redirect.
#
# This script:
#   1. Port-forwards AREG UI  → localhost:8080
#   2. Port-forwards Dex      → localhost:5556
#   3. Adds dex.dex.svc.cluster.local to /etc/hosts (once, requires sudo)
#   4. Opens http://localhost:8080 in the browser
#   5. Keeps both port-forwards alive (Ctrl-C to stop)
#
# Usage:
#   ./scripts/open-areg-ui.sh
#   KUBE_CONTEXT=cluster1-singtel ./scripts/open-areg-ui.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
AREG_SVC="${AREG_SVC:-agentregistry-agentregistry-enterprise}"
AREG_LOCAL_PORT="${AREG_LOCAL_PORT:-8080}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
DEX_LOCAL_PORT="${DEX_LOCAL_PORT:-5556}"
DEX_USER="${DEX_USER:-demo@example.com}"
DEX_PASS="${DEX_PASS:-demo-pass}"

KC="kubectl --context ${KUBE_CONTEXT}"

log()  { echo ""; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; }

###############################################################################
# 1. Kill any stale port-forwards on these ports
###############################################################################
pkill -f "port-forward.*${AREG_SVC}.*${AREG_LOCAL_PORT}" 2>/dev/null || true
pkill -f "port-forward.*dex.*${DEX_LOCAL_PORT}"           2>/dev/null || true
sleep 1

###############################################################################
# 2. Start port-forwards
###############################################################################
log "Starting port-forwards"
${KC} -n "${AREG_NAMESPACE}" port-forward "svc/${AREG_SVC}" "${AREG_LOCAL_PORT}:8080" &>/dev/null &
PF_AREG=$!

${KC} -n "${DEX_NAMESPACE}" port-forward svc/dex "${DEX_LOCAL_PORT}:5556" &>/dev/null &
PF_DEX=$!

cleanup() { kill "${PF_AREG}" "${PF_DEX}" 2>/dev/null || true; }
trap cleanup EXIT

for port in "${AREG_LOCAL_PORT}" "${DEX_LOCAL_PORT}"; do
  for i in $(seq 1 15); do
    if curl -s --max-time 2 "http://localhost:${port}" &>/dev/null; then
      ok "Port-forward :${port} ready"
      break
    fi
    [[ ${i} -eq 15 ]] && { echo "  ✗ Port-forward :${port} not ready after 15s"; exit 1; }
    sleep 1
  done
done

###############################################################################
# 3. /etc/hosts entry so the browser can resolve Dex's internal hostname
###############################################################################
DEX_HOSTS_ENTRY="127.0.0.1 dex.dex.svc.cluster.local"
if grep -q "dex.dex.svc.cluster.local" /etc/hosts 2>/dev/null; then
  ok "/etc/hosts already has dex.dex.svc.cluster.local"
else
  log "Adding Dex to /etc/hosts (sudo required)"
  if sudo sh -c "echo '${DEX_HOSTS_ENTRY}' >> /etc/hosts"; then
    ok "Added: ${DEX_HOSTS_ENTRY}"
  else
    echo ""
    echo "  Could not write /etc/hosts. Add this line manually, then reload:"
    echo "    ${DEX_HOSTS_ENTRY}"
  fi
fi

###############################################################################
# 4. Open the UI
###############################################################################
log "AgentRegistry UI"
echo ""
echo "  URL:      http://localhost:${AREG_LOCAL_PORT}"
echo "  Log in:   ${DEX_USER} / ${DEX_PASS}"
echo ""
echo "  Press Ctrl-C to stop."
echo ""

open "http://localhost:${AREG_LOCAL_PORT}" 2>/dev/null || \
  xdg-open "http://localhost:${AREG_LOCAL_PORT}" 2>/dev/null || true

trap - EXIT
wait
