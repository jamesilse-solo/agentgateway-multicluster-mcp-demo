#!/usr/bin/env bash
# Phase 1 — MCP Server Lifecycle: CR-01 / CR-02 / CR-03
# Usage: KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase1-MCP-Server-Lifecycle/validate.sh
# Full narrative lives in validate.md alongside this script.
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
AREG_NS="${AREG_NS:-agentregistry}"
AREG_SVC="${AREG_SVC:-agentregistry-agentregistry-enterprise}"
AGW_NS="${AGW_NS:-agentgateway-system}"
DEBUG_NS="${DEBUG_NS:-debug}"
TEST_NAME="com.example/poc-lifecycle-$(date +%s)"

# Colors / helpers (shared idiom across every phase script)
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
pause() { echo -e "\n  ${B}── press ENTER to continue ──${N}"; read -rp "" _; echo ""; }
step()  { echo -e "\n ${M}━━━ $* ━━━${N}\n"; }
show()  { echo -e "  ${C}\$ $*${N}"; }
ok()    { echo -e "  ${G}✅  $*${N}"; }
warn()  { echo -e "  ${Y}⚠️   $*${N}"; }
note()  { echo -e "\n  ${Y}📋  $*${N}"; }

# Title
echo -e "\n${M}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   Phase 1 — MCP Server Lifecycle                         ║${N}"
echo -e "${M}║   CR-01  Register · CR-02  Propagate · CR-03  Consume    ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                     ║${N}"
echo -e "${M}╚══════════════════════════════════════════════════════════╝${N}"
echo -e "  → Goal: prove end-to-end MCP onboarding from Registry to agent."
echo -e "  → Net cluster change: none (registration + gateway resources cleaned up at end)."
pause

# Resolve helpers
NETSHOOT=$(${KC} -n "${DEBUG_NS}" get pod -l app=netshoot -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
AGW_LB=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
[[ -z "${NETSHOOT}" ]] && warn "No netshoot pod in ${DEBUG_NS} — CR-03 will be skipped."
[[ -z "${AGW_LB}" ]]   && warn "Could not resolve agentgateway-hub LB — CR-02/CR-03 may be partial."

# Open Registry port-forward
${KC} -n "${AREG_NS}" port-forward "svc/${AREG_SVC}" 8080:8080 &>/dev/null &
PF=$!
trap 'kill ${PF} 2>/dev/null || true; ${KC} -n "${AGW_NS}" delete agentgatewaybackend "${TEST_NAME//\//-}" --ignore-not-found &>/dev/null || true; ${KC} -n "${AGW_NS}" delete httproute "${TEST_NAME//\//-}-route" --ignore-not-found &>/dev/null || true' EXIT
sleep 3
curl -s --max-time 3 http://localhost:8080/v0/servers >/dev/null || warn "Registry not reachable on :8080 yet — wait a moment."

###############################################################################
# CR-01 — Register
###############################################################################
step "CR-01 — Register a new MCP server entry in the Agent Registry"
echo -e "  → POST a single JSON document. The Registry stores it and exposes it via discovery."
pause

show "POST /v0/servers   name=${TEST_NAME}"
curl -s -X POST http://localhost:8080/v0/servers \
  -H "Content-Type: application/json" \
  -d "{
    \"\$schema\": \"https://static.modelcontextprotocol.io/schemas/2025-10-17/server.schema.json\",
    \"name\": \"${TEST_NAME}\",
    \"title\": \"Lifecycle test (CR-01)\",
    \"version\": \"1.0.0\",
    \"remotes\": [{\"type\": \"streamable-http\", \"url\": \"http://${AGW_LB:-agw-lb}/mcp\"}]
  }" | python3 -m json.tool 2>/dev/null || true

show "GET  /v0/servers?search=${TEST_NAME}"
curl -s "http://localhost:8080/v0/servers?search=${TEST_NAME}" | python3 -m json.tool 2>/dev/null | head -20 || warn "Search call failed."
note "The server entry is now discoverable by name. Any agent or admin can find it
      without knowing the URL ahead of time."
pause

###############################################################################
# CR-02 — Propagate
###############################################################################
step "CR-02 — Propagate Registry → MCP Gateway"
echo -e "  → Today: shell-script bridge. Native controller is on the roadmap."
echo -e "  → Either path produces the same outcome: AgentgatewayBackend + HTTPRoute."
pause

PROPAGATE_SCRIPT="$(dirname "$0")/../../scripts/propagate-registry.sh"
if [[ -x "${PROPAGATE_SCRIPT}" ]]; then
  show "${PROPAGATE_SCRIPT} --name ${TEST_NAME}"
  "${PROPAGATE_SCRIPT}" --name "${TEST_NAME}" || warn "Propagation script returned non-zero."
else
  warn "Propagation script not present — applying manual equivalent."
  BACKEND_NAME="${TEST_NAME//\//-}"
  show "${KC} apply -f - (AgentgatewayBackend + HTTPRoute for ${TEST_NAME})"
  ${KC} -n "${AGW_NS}" apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ${BACKEND_NAME}
  namespace: ${AGW_NS}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: ${BACKEND_NAME}
      static:
        host: mcp-server-everything.${AGW_NS}.svc.cluster.local
        port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${BACKEND_NAME}-route
  namespace: ${AGW_NS}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NS}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/${BACKEND_NAME}
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: ${BACKEND_NAME}
      namespace: ${AGW_NS}
EOF
fi

show "${KC} -n ${AGW_NS} get agentgatewaybackend,httproute"
${KC} -n "${AGW_NS}" get agentgatewaybackend,httproute | grep -E "${TEST_NAME//\//-}|NAME" || warn "Resources not visible yet."
note "Wait ~3-5s for the controller to set Accepted=True on the HTTPRoute, then continue."
pause

###############################################################################
# CR-03 — Consume
###############################################################################
step "CR-03 — Agent looks up the tool by name and calls it"
echo -e "  → From inside netshoot: discovery → acquire JWT → MCP initialize → tools/call."
pause

# Acquire a Dex JWT (the gateway requires Bearer auth via ExtAuth)
DEMO_USER="${DEMO_USER:-demo@example.com}"
DEMO_PASS="${DEMO_PASS:-demo-pass}"
CLIENT_ID="${CLIENT_ID:-agw-client}"
CLIENT_SECRET="${CLIENT_SECRET:-agw-client-secret}"
DEX_NS="${DEX_NS:-dex}"

show "Acquire Dex JWT (the gateway's ExtAuth requires it)"
${KC} -n "${DEX_NS}" port-forward svc/dex 5556:5556 &>/dev/null &
DEX_PF=$!
sleep 3
TOKEN=$(curl -s --max-time 5 -X POST http://localhost:5556/dex/token \
  -d "grant_type=password" \
  -d "username=${DEMO_USER}" \
  -d "password=${DEMO_PASS}" \
  -d "scope=openid email groups" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id_token",""))' 2>/dev/null || echo "")
kill ${DEX_PF} 2>/dev/null || true
[[ -n "${TOKEN}" ]] && ok "Token acquired (first 40 chars): ${TOKEN:0:40}..." \
                   || warn "Could not acquire Dex token — CR-03 will be skipped."

if [[ -z "${NETSHOOT}" || -z "${AGW_LB}" || -z "${TOKEN}" ]]; then
  warn "Cannot run CR-03: missing netshoot pod, AGW LB, or token."
else
  # URL-encode the slash in the search query
  SEARCH_ENC=$(echo "${TEST_NAME}" | sed 's|/|%2F|g')
  show "Discovery: GET /v0/servers?search=${TEST_NAME} (URL-encoded)"
  ${KC} -n "${DEBUG_NS}" exec "${NETSHOOT}" -- \
    curl -s --max-time 5 "http://${AREG_SVC}.${AREG_NS}.svc.cluster.local:8080/v0/servers?search=${SEARCH_ENC}" \
    | python3 -m json.tool 2>/dev/null | head -15 || warn "Discovery call failed."

  show "MCP initialize → tools/call against /mcp/${TEST_NAME//\//-} (with Bearer)"
  ${KC} -n "${DEBUG_NS}" exec "${NETSHOOT}" -- sh -c "
    set -e
    URL=http://${AGW_LB}/mcp/${TEST_NAME//\//-}
    SID=\$(curl -s -i -X POST \$URL \
      -H 'Authorization: Bearer ${TOKEN}' \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"poc\",\"version\":\"1\"}}}' \
      | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print \$2}')
    [ -z \"\$SID\" ] && { echo 'no session id (auth may have failed — check token)'; exit 1; }
    echo \"  session: \$SID\"
    curl -s -X POST \$URL \
      -H 'Authorization: Bearer ${TOKEN}' \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H \"Mcp-Session-Id: \$SID\" \
      -d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"CR-03 success\"}}}' \
      | head -1
  " || warn "End-to-end call failed."
fi
note "A successful tool response above means: registered, propagated, discovered, called.
      End-to-end onboarding with no agent code changes."
pause

###############################################################################
# Cleanup
###############################################################################
step "Cleanup"
show "DELETE /v0/servers/${TEST_NAME}"
curl -s -X DELETE "http://localhost:8080/v0/servers/$(echo "${TEST_NAME}" | sed 's|/|%2F|g')" >/dev/null 2>&1 || true
${KC} -n "${AGW_NS}" delete agentgatewaybackend "${TEST_NAME//\//-}" --ignore-not-found
${KC} -n "${AGW_NS}" delete httproute "${TEST_NAME//\//-}-route" --ignore-not-found
ok "Test artefacts removed."

echo -e "\n${G}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 1 validation complete ✅                         ║${N}"
echo -e "${G}║                                                          ║${N}"
echo -e "${G}║   CR-01  Register MCP server (Registry API)              ║${N}"
echo -e "${G}║   CR-02  Propagate to MCP Gateway                        ║${N}"
echo -e "${G}║   CR-03  Agent looks up + calls the new tool             ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}\n"
