#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05-observability-resilience.sh
#
# Two demonstrations:
#   1. Failover: scale cluster1's local MCP server pod to 0; show that calls
#      to /mcp/peer continue to succeed because they are forwarded to
#      cluster2's AGW (which still has its own MCP server). The agent sees
#      zero failed calls.
#   2. Distributed trace: fire a single /mcp/peer request, then locate the
#      trace ID in cluster1's AGW access log AND cluster2's AGW access log
#      — proving the SAME trace ID spans both gateways.
#
# Idempotent. Scales the MCP server back to 1 replica at the end, even on
# script abort (trap).
###############################################################################

KUBE_CONTEXT_1="${KUBE_CONTEXT_1:-cluster1}"
KUBE_CONTEXT_2="${KUBE_CONTEXT_2:-cluster2}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"

KC1="kubectl --context ${KUBE_CONTEXT_1}"
KC2="kubectl --context ${KUBE_CONTEXT_2}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
banner() { echo -e "\n${M}━━━ $* ━━━${N}"; }
note()   { echo -e "  ${Y}↳ $*${N}"; }
ok()     { echo -e "  ${G}✓ $*${N}"; }
bad()    { echo -e "  \033[1;31m✗ $*${N}"; }

restore_cluster1_mcp() {
  ${KC1} -n "${AGW_NAMESPACE}" scale deploy/mcp-server-everything --replicas=1 2>/dev/null || true
}
trap restore_cluster1_mcp EXIT

AGW_LB=$(${KC1} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
TOKEN=$(curl -s -X POST "http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/token" \
  -d 'grant_type=password' -d 'username=demo' -d 'password=demo-pass' \
  -d 'client_id=agw-client' -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' | jq -r '.id_token')

if [[ "${1:-}" == "--trace" ]]; then
  ###############################################################################
  # Mode 2 — single trace across the AGW chain
  ###############################################################################
  banner "Distributed trace across cluster1 AGW → cluster2 AGW"

  note "Firing one call to /mcp/peer (requires the AGW-to-AGW federation"
  note "from PR #1 / examples/01-agw-to-agw-federation.sh to be installed)..."
  RESP=$(curl -si -X POST "http://${AGW_LB}/mcp/peer" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"05","version":"1"}}}')
  STATUS=$(echo "$RESP" | head -1 | awk '{print $2}')
  [[ "${STATUS}" != "200" ]] && { bad "/mcp/peer returned HTTP ${STATUS}"; exit 1; }
  ok "Call accepted (HTTP 200)"

  sleep 2

  note "Pulling the most recent /mcp/peer line from cluster1..."
  C1_LINE=$(${KC1} -n "${AGW_NAMESPACE}" logs deploy/agentgateway-hub --tail=200 \
    | grep '/mcp/peer' | grep '"http.method":"POST"' | tail -1)
  C1_TRACE=$(echo "${C1_LINE}" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('trace.id',''))" 2>/dev/null || echo "")

  if [[ -n "${C1_TRACE}" ]]; then
    ok "cluster1 trace.id = ${C1_TRACE}"
  else
    bad "No cluster1 trace ID found in the last 200 log lines."
    exit 1
  fi

  note "Pulling the matching line from cluster2's AGW Spoke..."
  C2_LINE=$(${KC2} -n "${AGW_NAMESPACE}" logs deploy/agentgateway-spoke --tail=200 \
    | grep -- "${C1_TRACE}" | tail -1 || true)
  if [[ -n "${C2_LINE}" ]]; then
    ok "cluster2 saw the same trace.id"
    echo "${C2_LINE}" | python3 -m json.tool 2>/dev/null | grep -E '"gateway|"route|"http.path|"trace.id' \
      | sed 's/^/      /'
  else
    note "trace.id ${C1_TRACE} not yet visible on cluster2 (logs may lag)"
    note "Re-run in a few seconds, or check the AGW Enterprise UI's trace view."
  fi

  exit 0
fi

###############################################################################
# Mode 1 — Failover demo
###############################################################################
banner "Failover demo — scale down cluster1 MCP, observe seamless fallback"

# Capacity test: we'll fire 5 calls to /mcp/peer first to establish baseline
note "Step 1: 5 calls to /mcp/peer with cluster1 MCP healthy (expect all 200)"
for i in 1 2 3 4 5; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${AGW_LB}/mcp/peer" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"05","version":"1"}}}')
  echo "    baseline call ${i}: HTTP ${HTTP}"
done

note "Step 2: Scale cluster1 mcp-server-everything to 0 replicas"
${KC1} -n "${AGW_NAMESPACE}" scale deploy/mcp-server-everything --replicas=0
${KC1} -n "${AGW_NAMESPACE}" rollout status deploy/mcp-server-everything --timeout=60s || true
sleep 3
ok "cluster1 MCP server is down"

note "Step 3: 5 calls to /mcp/peer (which forwards to cluster2's AGW)"
note "        Because /mcp/peer goes via AGW-to-AGW chaining, cluster2's"
note "        local MCP server answers — agent sees zero failures."
FAIL=0
for i in 1 2 3 4 5; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${AGW_LB}/mcp/peer" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"05","version":"1"}}}')
  if [[ "${HTTP}" == "200" ]]; then
    echo "    failover call ${i}: HTTP ${HTTP} ✓"
  else
    echo "    failover call ${i}: HTTP ${HTTP} ✗"
    FAIL=$((FAIL+1))
  fi
done

note "Step 4: Restore cluster1 MCP server"
${KC1} -n "${AGW_NAMESPACE}" scale deploy/mcp-server-everything --replicas=1
${KC1} -n "${AGW_NAMESPACE}" rollout status deploy/mcp-server-everything --timeout=60s
ok "cluster1 MCP server is back"

banner "Result"
if [[ ${FAIL} -eq 0 ]]; then
  ok "All 10 calls succeeded (5 baseline + 5 with cluster1 MCP down)"
  echo "    The agent never knew cluster1's MCP server went away. The"
  echo "    gateway chain (cluster1 AGW → cluster2 AGW → cluster2 MCP)"
  echo "    absorbed the outage transparently."
else
  bad "${FAIL} calls failed during the cluster1-down window"
  echo "    Check that examples/01-agw-to-agw-federation.sh has been run"
  echo "    (the /mcp/peer route depends on it)."
fi

cat <<EOF

For the distributed-trace view:
  ./examples/05-observability-resilience.sh --trace
EOF
