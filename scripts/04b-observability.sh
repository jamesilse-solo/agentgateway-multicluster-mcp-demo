#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04b-observability.sh — MCP-aware observability + failover demo prereqs
#
# AgentGateway 2.3.3 already emits MCP-specific metric fields on every
# request (mcp.method.name, mcp.session.id, mcp.tool.name — visible in the
# access log lines). This script:
#   1. Verifies those fields are present on the access logs (informational).
#   2. Ensures the AGW Enterprise UI / OTel collector / ClickHouse stack
#      from 04a-agw-management-ui.sh is healthy (reports if not).
#   3. Prints follow-up commands for the failover demo (which lives in
#      examples/05-observability-resilience.sh — it does not modify
#      cluster state on its own).
#
# This is a verification + diagnostic script, not a state-changing one.
#
# Prerequisites:
#   - 04a-agw-management-ui.sh has been run
#
# Usage:
#   ./scripts/04b-observability.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; }

###############################################################################
# Check 1 — MCP-specific log fields on the AGW data plane
###############################################################################
log "Check 1 — MCP metric fields on AGW access logs"
RECENT_LOG=$(${KC} -n "${AGW_NAMESPACE}" logs deploy/agentgateway-hub --tail=200 2>&1 \
  | grep -i 'mcp.method.name' | tail -1)
if [[ -n "${RECENT_LOG}" ]]; then
  ok "Found access log with mcp.method.name field:"
  echo "${RECENT_LOG}" | python3 -m json.tool 2>/dev/null | grep -E '"mcp|"route|"http.method|"http.status' \
    | sed 's/^/      /' || echo "${RECENT_LOG:0:200}..." | sed 's/^/      /'
else
  bad "No recent log lines with mcp.method.name found."
  echo "    Send some MCP traffic first (./demo/send-traffic.sh) and retry."
fi

###############################################################################
# Check 2 — Solo Enterprise UI / ClickHouse / OTel collector status
###############################################################################
log "Check 2 — Telemetry stack"
for D in solo-enterprise-ui solo-enterprise-telemetry-collector solo-enterprise-clickhouse; do
  if ${KC} -n "${AGW_NAMESPACE}" get pod -l app.kubernetes.io/name=${D} \
      -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running; then
    ok "${D}: Running"
  else
    bad "${D}: not Running (re-run scripts/04a-agw-management-ui.sh)"
  fi
done

###############################################################################
# Check 3 — Cluster2 telemetry shipment
###############################################################################
log "Check 3 — Cluster2 telemetry shipment to cluster1"
if kubectl --context "${KUBE_CONTEXT/cluster1/cluster2}" -n "${AGW_NAMESPACE}" \
    get pod -l app.kubernetes.io/name=solo-enterprise-telemetry-collector \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running; then
  ok "cluster2 telemetry collector: Running"
else
  bad "cluster2 telemetry collector: not Running or context not configured"
fi

###############################################################################
# Summary
###############################################################################
log "Next steps"
cat <<EOF

  • Send live traffic and watch metrics:
      ./demo/send-traffic.sh
      Open the AGW Enterprise UI (./demo/portforward.sh) at http://localhost:4000

  • Run the failover demo:
      ./examples/05-observability-resilience.sh

  • Inspect a single distributed trace across the AGW-to-AGW chain:
      ./examples/05-observability-resilience.sh --trace

This script is read-only. It does not modify cluster state.
EOF
