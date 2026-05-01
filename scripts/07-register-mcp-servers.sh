#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 07-register-mcp-servers.sh — Register MCP servers in AgentRegistry
#
# Registers three MCP servers into the AgentRegistry Enterprise catalog:
#   1. com.amazonaws/mcp-everything-local  — mcp-server-everything on cluster1
#                                            served via AgentGateway hub at /mcp
#   2. com.amazonaws/mcp-everything-remote — mcp-server-everything on cluster2
#                                            served via AgentGateway hub at /mcp/remote
#   3. io.solo/search-solo-io              — Solo.io docs search MCP server at
#                                            https://search.solo.io/mcp (public)
#
# Namespace convention (MCP registry):
#   Server names follow reverse-domain notation. The registry validates that
#   the remote URL's hostname ends in the reversed namespace. For example:
#     io.solo/* → URLs must be on *.solo.io
#     com.amazonaws/* → URLs must be on *.amazonaws.com (ELB hostnames)
#
# Prerequisites:
#   - 04-areg.sh has run and AgentRegistry is Running
#
# Usage:
#   ./scripts/07-register-mcp-servers.sh
#   KUBE_CONTEXT=cluster1-singtel ./scripts/07-register-mcp-servers.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
AREG_SVC="${AREG_SVC:-agentregistry-agentregistry-enterprise}"
AREG_LOCAL_PORT="${AREG_LOCAL_PORT:-8080}"
# Enterprise service exposes HTTP UI + API directly on port 8080
AREG_SVC_PORT="${AREG_SVC_PORT:-8080}"

KC="kubectl --context ${KUBE_CONTEXT}"
SCHEMA="https://static.modelcontextprotocol.io/schemas/2025-10-17/server.schema.json"

log()  { echo ""; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; }

###############################################################################
# 1. Resolve AgentGateway LB address
###############################################################################
log "Resolving AgentGateway LB"
AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [[ -z "${AGW_LB}" ]]; then
  echo "ERROR: Could not resolve AgentGateway LB. Is agentgateway-hub running?"
  exit 1
fi
ok "AgentGateway LB: ${AGW_LB}"

###############################################################################
# 2. Port-forward AgentRegistry
###############################################################################
log "Starting port-forward"

pkill -f "port-forward.*${AREG_SVC}.*${AREG_LOCAL_PORT}" 2>/dev/null || true
sleep 1

${KC} -n "${AREG_NAMESPACE}" port-forward "svc/${AREG_SVC}" "${AREG_LOCAL_PORT}:${AREG_SVC_PORT}" &>/dev/null &
PF_AREG=$!
trap 'kill "${PF_AREG}" 2>/dev/null || true' EXIT

for i in $(seq 1 15); do
  if curl -s --max-time 2 "http://localhost:${AREG_LOCAL_PORT}/v0/servers" &>/dev/null; then
    ok "Port-forward :${AREG_LOCAL_PORT} ready"
    break
  fi
  [[ ${i} -eq 15 ]] && { fail "Port-forward not ready after 15s"; exit 1; }
  sleep 1
done

###############################################################################
# 3. Register MCP servers
###############################################################################
log "Registering MCP servers"

register_server() {
  local payload="$1"
  local result
  result=$(curl -s --max-time 15 -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "http://localhost:${AREG_LOCAL_PORT}/v0/servers" \
    -d "${payload}" 2>/dev/null)

  local name
  name=$(echo "${result}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('server',{}).get('name',''))" 2>/dev/null || echo "")

  if [[ -n "${name}" ]]; then
    ok "Registered: ${name}"
  else
    local err
    err=$(echo "${result}" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); \
      errs=d.get('errors',[{}]); msg=errs[0].get('message',d.get('detail','unknown')) if errs else d.get('detail','unknown'); \
      print(msg)" 2>/dev/null || echo "${result}")
    # 409 = duplicate entry; 400 "duplicate version" = already registered
    if echo "${result}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
status = d.get('status', 0)
errs = d.get('errors', [])
dup_ver = any('duplicate version' in e.get('message','') for e in errs)
exit(0 if status == 409 or dup_ver else 1)
" 2>/dev/null; then
      ok "Already registered (skipping): $(echo "${payload}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','?'))" 2>/dev/null)"
    else
      fail "Registration failed: ${err}"
    fi
  fi
}

# ── Server 1: mcp-server-everything on cluster1 (via AGW /mcp) ──────────────
register_server "{
  \"\$schema\": \"${SCHEMA}\",
  \"name\": \"com.amazonaws/mcp-everything-local\",
  \"title\": \"MCP Everything — cluster1 (local)\",
  \"description\": \"MCP reference server on cluster1\",
  \"version\": \"1.0.0\",
  \"remotes\": [{\"type\": \"streamable-http\", \"url\": \"http://${AGW_LB}/mcp\"}]
}"

# ── Server 2: mcp-server-everything on cluster2 (via AGW /mcp/remote) ────────
register_server "{
  \"\$schema\": \"${SCHEMA}\",
  \"name\": \"com.amazonaws/mcp-everything-remote\",
  \"title\": \"MCP Everything — cluster2 (remote, cross-cluster)\",
  \"description\": \"MCP reference server on cluster2 routed cross-cluster\",
  \"version\": \"1.0.0\",
  \"remotes\": [{\"type\": \"streamable-http\", \"url\": \"http://${AGW_LB}/mcp/remote\"}]
}"

# ── Server 3: Solo.io docs search (public, https://search.solo.io/mcp) ───────
register_server "{
  \"\$schema\": \"${SCHEMA}\",
  \"name\": \"io.solo/search-solo-io\",
  \"title\": \"Solo.io Docs MCP\",
  \"description\": \"Solo.io documentation search MCP server\",
  \"version\": \"1.0.0\",
  \"remotes\": [{\"type\": \"streamable-http\", \"url\": \"https://search.solo.io/mcp\"}]
}"

###############################################################################
# 4. Verify
###############################################################################
log "Verification"

for ns in "com.amazonaws" "io.solo"; do
  curl -s --max-time 10 \
    -H "Accept: application/json" \
    "http://localhost:${AREG_LOCAL_PORT}/v0/servers?search=${ns}" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('servers', []):
    srv = s['server']
    url = (srv.get('remotes') or [{}])[0].get('url', '(no url)')
    print(f'  ✓ {srv[\"name\"]:55s}  {url}')
" 2>/dev/null
done

###############################################################################
# 5. Open AgentRegistry UI
###############################################################################
log "AgentRegistry UI"
echo ""
echo "  Port-forward is still active. Open the UI in your browser:"
echo ""
echo "    http://localhost:${AREG_LOCAL_PORT}"
echo ""
echo "  Navigate to 'Servers' to see the three registered entries."
echo "  Press Ctrl-C to stop the port-forward when done."
echo ""

trap - EXIT
wait
