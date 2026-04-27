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
#   - 03-dex.sh, 04-areg-enterprise.sh have run
#   - AgentRegistry is running (kubectl -n agentregistry get pods)
#
# Usage:
#   ./scripts/07-register-mcp-servers.sh
#   KUBE_CONTEXT=cluster1-singtel ./scripts/07-register-mcp-servers.sh
#
# This is the standard post-Phase-4 step. Run it once after 04-areg-enterprise.sh
# to populate the AgentRegistry catalog with the deployed MCP servers.
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
AREG_SVC="${AREG_SVC:-agentregistry-agentregistry-enterprise}"
AREG_LOCAL_PORT="${AREG_LOCAL_PORT:-8080}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
DEX_LOCAL_PORT="${DEX_LOCAL_PORT:-5556}"
# areg-public is the OIDC public client registered for AgentRegistry.
# It does not use a client secret (public client). agw-client is a confidential
# client intended for AgentGateway and has read-only access to AREG.
DEX_CLIENT_ID="${DEX_CLIENT_ID:-areg-public}"
DEX_USER="${DEX_USER:-demo@example.com}"
DEX_PASS="${DEX_PASS:-demo-pass}"

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
# 2. Port-forward AgentRegistry (HTTP/UI on 8080) and Dex (5556)
#
# The AREG UI redirects the browser to Dex using the internal cluster
# hostname (dex.dex.svc.cluster.local:5556). For the browser to follow
# that redirect we:
#   a) port-forward Dex on localhost:5556
#   b) add 127.0.0.1 dex.dex.svc.cluster.local to /etc/hosts (needs sudo)
###############################################################################
log "Starting port-forwards"

pkill -f "port-forward.*${AREG_SVC}.*${AREG_LOCAL_PORT}" 2>/dev/null || true
pkill -f "port-forward.*dex.*${DEX_LOCAL_PORT}" 2>/dev/null || true
sleep 1

${KC} -n "${AREG_NAMESPACE}" port-forward "svc/${AREG_SVC}" "${AREG_LOCAL_PORT}:8080" &>/dev/null &
PF_AREG=$!

${KC} -n "${DEX_NAMESPACE}" port-forward svc/dex "${DEX_LOCAL_PORT}:5556" &>/dev/null &
PF_DEX=$!

cleanup() {
  kill "${PF_AREG}" "${PF_DEX}" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for both to be ready
for port in "${AREG_LOCAL_PORT}" "${DEX_LOCAL_PORT}"; do
  for i in $(seq 1 15); do
    if curl -s --max-time 2 "http://localhost:${port}" &>/dev/null; then
      ok "Port-forward :${port} ready"
      break
    fi
    if [[ ${i} -eq 15 ]]; then
      fail "Port-forward :${port} not ready after 15s"
      exit 1
    fi
    sleep 1
  done
done

# Ensure the internal Dex hostname resolves to localhost so the browser can
# follow the OIDC redirect. Add it to /etc/hosts if not already present.
DEX_HOSTS_ENTRY="127.0.0.1 dex.dex.svc.cluster.local"
if grep -q "dex.dex.svc.cluster.local" /etc/hosts 2>/dev/null; then
  ok "/etc/hosts already has dex.dex.svc.cluster.local"
else
  echo ""
  echo "  The AREG UI redirects the browser to dex.dex.svc.cluster.local:${DEX_LOCAL_PORT}."
  echo "  Adding a /etc/hosts entry so your browser resolves it to localhost."
  echo "  (sudo password may be required)"
  echo ""
  if sudo sh -c "echo '${DEX_HOSTS_ENTRY}' >> /etc/hosts"; then
    ok "Added to /etc/hosts: ${DEX_HOSTS_ENTRY}"
  else
    echo ""
    echo "  Could not write /etc/hosts. Add this line manually, then re-open the browser:"
    echo "    ${DEX_HOSTS_ENTRY}"
    echo ""
  fi
fi

###############################################################################
# 3. Acquire auth token from Dex
###############################################################################
log "Acquiring Bearer token from Dex"

TOKEN=$(curl -s --max-time 10 -X POST "http://localhost:${DEX_LOCAL_PORT}/dex/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "grant_type=password&username=${DEX_USER}&password=${DEX_PASS}&client_id=${DEX_CLIENT_ID}&scope=openid+email+profile" \
  | python3 -c "import sys,json; t=json.load(sys.stdin); print(t.get('access_token',''))" 2>/dev/null)

if [[ -z "${TOKEN}" ]]; then
  fail "Token acquisition failed — check Dex is running and credentials are correct"
  exit 1
fi
ok "Token acquired for ${DEX_USER}"

###############################################################################
# 4. Register MCP servers
###############################################################################
log "Registering MCP servers"

# Helper: POST to /v0/servers, returns the registered name or error
register_server() {
  local payload="$1"
  local result
  result=$(curl -s --max-time 15 -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
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
    # 409 = duplicate entry; 400 "duplicate version" = seed data already has this
    # version — treat both as "already registered" and continue.
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
# Namespace: com.amazonaws (ELB hostname ends in amazonaws.com)
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
# Namespace: io.solo (URL host ends in solo.io)
register_server "{
  \"\$schema\": \"${SCHEMA}\",
  \"name\": \"io.solo/search-solo-io\",
  \"title\": \"Solo.io Docs MCP\",
  \"description\": \"Solo.io documentation search MCP server\",
  \"version\": \"1.0.0\",
  \"remotes\": [{\"type\": \"streamable-http\", \"url\": \"https://search.solo.io/mcp\"}]
}"

###############################################################################
# 5. Verify
###############################################################################
log "Verification"

for ns in "com.amazonaws" "io.solo"; do
  curl -s --max-time 10 \
    -H "Authorization: Bearer ${TOKEN}" \
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
# 6. Open AgentRegistry UI
###############################################################################
log "AgentRegistry UI"
echo ""
echo "  Port-forward is still active. Open the UI in your browser:"
echo ""
echo "    http://localhost:${AREG_LOCAL_PORT}"
echo ""
echo "  Log in with:  ${DEX_USER} / ${DEX_PASS}"
echo ""
echo "  Navigate to 'Servers' to see the three registered entries."
echo "  Press Ctrl-C to stop the port-forward when done."
echo ""

# Keep port-forwards alive until the user stops the script
trap - EXIT
wait
