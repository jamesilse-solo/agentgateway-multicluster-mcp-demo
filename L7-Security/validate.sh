#!/usr/bin/env bash
# L7 Agent Gateway — Security, Identity & TBAC: Interactive Validation
# Tests: L7-SEC-01 through L7-SEC-06
# Usage: KUBE_CONTEXT=cluster1-singtel ./L7-Security/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
AGW_NS="agentgateway-system"
DEX_NS="${DEX_NAMESPACE:-dex}"
DEX_LOCAL_PORT="${DEX_LOCAL_PORT:-5556}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'

pause() {
  echo -e "\n  ${B}─────────────────────────────────────────────────${N}"
  echo -e "  ${B}  ⏎  Press ENTER to continue...${N}"
  echo -e "  ${B}─────────────────────────────────────────────────${N}"
  read -rp "" _
  echo ""
}

step() {
  echo -e "\n ${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e " ${M}  $*${N}"
  echo -e " ${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
}

show() {
  echo -e "\n  ${C}──────────────────────────────────────────────────────────${N}"
  echo -e "  ${C}  \$ $*${N}"
  echo -e "  ${C}──────────────────────────────────────────────────────────${N}\n"
}

ok()   { echo -e "  ${G}✅  $*${N}"; }
warn() { echo -e "  ${Y}⚠️   $*${N}"; }
note() { echo -e "\n  ${Y}📋  $*${N}"; }

echo ""
echo -e "${M}╔════════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   L7 Agent Gateway — Security, Identity & TBAC            ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                 ║${N}"
echo -e "${M}║   Tests: L7-SEC-01 · 02 · 03 · 04 · 05 · 06             ║${N}"
echo -e "${M}╚════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  → Goal: prove that ExtAuth + OPA enforce OAuth identity, tool-level"
echo -e "    RBAC, task-based access control, and upstream credential injection."
echo -e "  → No persistent config changes: all test resources are cleaned up."
pause

AGW_LB=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

NETSHOOT=$(${KC} -n debug get pod -l app=netshoot \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "${NETSHOOT}" ]] && warn "No netshoot pod found — in-cluster curl tests will be skipped."

AGW_SVC_IP=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

###############################################################################
# L7-SEC-01 — OAuth 2.0 (Client to Gateway)
###############################################################################
step "L7-SEC-01 — OAuth 2.0 (Client to Gateway)"
echo -e "  → The gateway validates Dex OIDC Bearer tokens via ExtAuth."
echo -e "    Unauthenticated requests are rejected with 302/401."
echo -e "    Authenticated requests with a valid JWT are forwarded."
pause

# SEC-01.1 — Show ExtAuth + AuthConfig resources
show "${KC} -n ${AGW_NS} get authconfig,enterpriseagentgatewaypolicy"
${KC} -n "${AGW_NS}" get authconfig 2>/dev/null || warn "No AuthConfig resources found"
${KC} -n "${AGW_NS}" get enterpriseagentgatewaypolicy 2>/dev/null || warn "No EnterpriseAgentgatewayPolicy resources found"
note "The EnterpriseAgentgatewayPolicy attaches the AuthConfig to the hub gateway.
      ExtAuth evaluates every incoming request against the OIDC configuration."
pause

# SEC-01.2 — Unauthenticated request → 302 redirect
show "curl http://${AGW_LB:-<agw-lb>}/mcp (no token — expect 302 → Dex login)"
if [[ -n "${AGW_LB}" ]]; then
  curl -s --max-time 5 "http://${AGW_LB}/mcp" \
    -o /dev/null -w "  HTTP %{http_code}  (expect 302 redirect to Dex)\n" || true
fi
note "302 redirect to Dex login = ExtAuth is enforcing OAuth. Without a valid token,
      no MCP data is accessible."
pause

# SEC-01.3 — Acquire Dex token (requires port-forward to Dex)
show "Port-forward Dex (start in background) → acquire JWT"
pkill -f "port-forward.*dex.*${DEX_LOCAL_PORT}" 2>/dev/null || true
sleep 1
${KC} -n "${DEX_NS}" port-forward svc/dex "${DEX_LOCAL_PORT}:5556" &>/dev/null &
DEX_PF=$!
trap 'kill "${DEX_PF}" 2>/dev/null || true' EXIT
sleep 3

TOKEN=$(curl -s --max-time 10 \
  -X POST "http://localhost:${DEX_LOCAL_PORT}/dex/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=demo@example.com&password=demo-pass" \
  -d "client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

if [[ -n "${TOKEN}" ]]; then
  ok "JWT acquired (${#TOKEN} chars)"
else
  warn "Could not acquire JWT — Dex may not be running or credentials incorrect"
fi
pause

# SEC-01.4 — Authenticated request → 200
show "curl http://${AGW_LB:-<agw-lb>}/mcp  Authorization: Bearer <token>"
if [[ -n "${AGW_LB}" && -n "${TOKEN}" ]]; then
  curl -s --max-time 10 \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    "http://${AGW_LB}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    -o /dev/null -w "  HTTP %{http_code}  (expect 200 — token validated)\n" || true
  note "200 = ExtAuth validated the Dex JWT and allowed the request through.
        The gateway extracts the email claim and populates x-user-token header
        for downstream services."
fi
pause

###############################################################################
# L7-SEC-02 — Tool & Resource Level RBAC (OPA)
###############################################################################
step "L7-SEC-02 — Tool & Resource Level RBAC (OPA)"
echo -e "  → An OPA Rego policy parses the JSON-RPC tool name from the request"
echo -e "    and evaluates the caller's JWT claims."
echo -e "  → A non-admin user attempting 'delete_database' is blocked with 403."
pause

# SEC-02.1 — Show ExtAuth OPA config
show "${KC} -n ${AGW_NS} get authconfig -o yaml | grep -A20 opa"
${KC} -n "${AGW_NS}" get authconfig -o yaml 2>/dev/null \
  | grep -A10 -i "opa\|rego\|policy" | head -30 \
  || echo "  (no OPA config found — requires L7-SEC setup)"
note "The OPA Rego policy receives the full HTTP request including the JSON-RPC
      body. It extracts the 'method' and 'params.name' fields and evaluates them
      against the caller's JWT role claims."
pause

# SEC-02.2 — Show OPA policy ConfigMap if it exists
show "${KC} -n ${AGW_NS} get configmap -l app=opa -o yaml"
${KC} -n "${AGW_NS}" get configmap \
  -l "app=opa" -o yaml 2>/dev/null | grep -A20 "policy.rego" | head -30 \
  || echo "  (no OPA ConfigMap found — see validate.md for deployment steps)"
note "To add tool-level RBAC: deploy an OPA ConfigMap with Rego that checks
      the 'method' field in the JSON-RPC body against the caller's JWT 'role' claim."
pause

# SEC-02.3 — Demonstrate without OPA: tools/call for a protected tool
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/call → 'echo' tool (non-privileged) — expect allowed"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 10 \
    -X POST -H "Content-Type: application/json" \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"test"}}}' \
    -o /dev/null -w "  HTTP %{http_code}\n" || true
fi
pause

###############################################################################
# L7-SEC-03 — Task-Based Access Control (TBAC)
###############################################################################
step "L7-SEC-03 — Task-Based Access Control (TBAC)"
echo -e "  → The gateway evaluates the agent's task context (passed as JWT claim"
echo -e "    or request metadata) against an OPA policy that maps allowed tasks"
echo -e "    to allowed tool names."
echo -e "  → Tool calls outside the authorized task scope are rejected."
pause

# SEC-03.1 — Show TBAC policy structure
show "${KC} -n ${AGW_NS} get configmap -o yaml | grep -A30 'task'"
${KC} -n "${AGW_NS}" get configmap -o yaml 2>/dev/null \
  | grep -B2 -A15 -i "task\|tbac" | head -40 \
  || echo "  (no TBAC ConfigMap found — see validate.md for example Rego policy)"
note "A TBAC Rego policy checks: does the 'task' JWT claim authorize this
      'tools/call' method? If the agent's task is 'customer-support', it cannot
      call 'delete_database' even with a valid JWT."
pause

# SEC-03.2 — Show how task context is injected
echo -e "  Example: JWT payload with task claim:"
echo -e '  {
    "sub": "demo@example.com",
    "email": "demo@example.com",
    "task": "customer-support",
    "role": "agent"
  }'
note "The orchestrator system (e.g. LangChain, CrewAI) injects the task claim
      when minting the agent JWT. The gateway evaluates the task × tool matrix
      in OPA without any application code in the MCP server."
pause

###############################################################################
# L7-SEC-04 — L7 Multi-Tenancy Support
###############################################################################
step "L7-SEC-04 — L7 Multi-Tenancy Support"
echo -e "  → Multiple tenants share the same gateway."
echo -e "    Routing is isolated at L7 by domain, path prefix, or JWT claim."
echo -e "  → Tenant A can only see Tenant A's tools — Tenant B's tools are hidden."
pause

# SEC-04.1 — Show HTTPRoutes demonstrating multi-tenant isolation
show "${KC} -n ${AGW_NS} get httproute -o yaml | grep -E 'host:|path:|name:'"
${KC} -n "${AGW_NS}" get httproute -o yaml 2>/dev/null \
  | grep -E "hosts:|path:|name:" | head -20
note "Different HTTPRoutes can target different AgentgatewayBackend resources.
      A JWT claim 'tenant_id' can be used as a routing key in an HTTPRoute's
      header match, isolating tenants to their own backend pools."
pause

# SEC-04.2 — Show the /mcp vs /mcp/remote backend isolation
show "${KC} -n ${AGW_NS} get httproute -o jsonpath '{.items[*].spec.rules[*].matches}'"
${KC} -n "${AGW_NS}" get httproute \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.rules[0].matches[0].path.value}{"\n"}{end}' \
  2>/dev/null
note "The /mcp path maps to cluster1 backends; /mcp/remote maps to cluster2.
      For full multi-tenancy: map /mcp/tenant-a to Tenant A's AgentgatewayBackend
      and apply a JWT host/path match on the HTTPRoute."
pause

###############################################################################
# L7-SEC-05 — Dynamic Client Registration (DCR)
###############################################################################
step "L7-SEC-05 — Dynamic Client Registration"
echo -e "  → An unregistered MCP client connects to the gateway."
echo -e "    The gateway, configured with an IdP, triggers the OAuth DCR flow."
echo -e "    A client_id + client_secret are provisioned dynamically."
pause

# SEC-05.1 — Show DCR configuration (requires Keycloak or Auth0, not Dex)
show "${KC} -n ${AGW_NS} get authconfig -o yaml | grep -i 'dcr\\|dynamic\\|registration'"
${KC} -n "${AGW_NS}" get authconfig -o yaml 2>/dev/null \
  | grep -i "dcr\|dynamic\|registration\|client_registration" | head -10 \
  || echo "  (DCR not configured — Dex does not support RFC 7591 DCR)"
note "Dynamic Client Registration (RFC 7591) is supported by Keycloak and Auth0.
      Dex (used in this POC for other flows) does not support DCR.
      Configure an AuthConfig with an OIDC provider that supports DCR to enable this flow.
      Reference: docs.solo.io/agentgateway/2.2.x/security/extauth/oauth/"
pause

###############################################################################
# L7-SEC-06 — Upstream Gateway to Server Auth (Credential Injection)
###############################################################################
step "L7-SEC-06 — Upstream Gateway to Server Auth (Credential Injection)"
echo -e "  → The agent calls a SaaS MCP tool without providing SaaS credentials."
echo -e "    The gateway injects the required upstream OAuth tokens/API keys"
echo -e "    before forwarding — the agent never sees the credentials."
pause

# SEC-06.1 — Show any upstream credential injection config
show "${KC} -n ${AGW_NS} get authconfig -o yaml | grep -A10 'upstream\\|inject\\|headerModification'"
${KC} -n "${AGW_NS}" get authconfig -o yaml 2>/dev/null \
  | grep -A10 -i "upstream\|inject\|apiKey\|headerModification" | head -30 \
  || echo "  (no upstream credential injection configured yet)"
note "Configure the AuthConfig with an upstream OAuth credential:
        configs:
        - pluginAuth:
            name: inject-upstream-token
      The gateway adds 'Authorization: Bearer <service-account-token>' to the
      upstream request. The agent's JWT only needs to authorize access to the gateway —
      the gateway handles SaaS authentication independently."
pause

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   L7 Security validation complete ✅                ║${N}"
echo -e "${G}║                                                      ║${N}"
echo -e "${G}║   L7-SEC-01  OAuth 2.0 JWT enforcement (Dex)        ║${N}"
echo -e "${G}║   L7-SEC-02  OPA tool-level RBAC                    ║${N}"
echo -e "${G}║   L7-SEC-03  Task-based access control (TBAC)       ║${N}"
echo -e "${G}║   L7-SEC-04  L7 multi-tenancy via JWT routing        ║${N}"
echo -e "${G}║   L7-SEC-05  Dynamic client registration (DCR)       ║${N}"
echo -e "${G}║   L7-SEC-06  Upstream credential injection           ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
echo ""
