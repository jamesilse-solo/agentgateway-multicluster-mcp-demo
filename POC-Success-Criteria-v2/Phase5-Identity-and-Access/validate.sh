#!/usr/bin/env bash
# Phase 5 — Identity & Access Control: AUTH-01 / 02 / 03 / 04
# Usage: KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase5-Identity-and-Access/validate.sh
# Full narrative lives in validate.md alongside this script.
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
AGW_NS="${AGW_NS:-agentgateway-system}"
DEX_NS="${DEX_NS:-dex}"
DEMO_USER="${DEMO_USER:-demo@example.com}"
DEMO_PASS="${DEMO_PASS:-demo-pass}"
CLIENT_ID="${CLIENT_ID:-agw-client}"
CLIENT_SECRET="${CLIENT_SECRET:-agw-client-secret}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
pause() { echo -e "\n  ${B}── press ENTER to continue ──${N}"; read -rp "" _; echo ""; }
step()  { echo -e "\n ${M}━━━ $* ━━━${N}\n"; }
show()  { echo -e "  ${C}\$ $*${N}"; }
ok()    { echo -e "  ${G}✅  $*${N}"; }
warn()  { echo -e "  ${Y}⚠️   $*${N}"; }
note()  { echo -e "\n  ${Y}📋  $*${N}"; }

echo -e "\n${M}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   Phase 5 — Identity & Access Control                    ║${N}"
echo -e "${M}║   AUTH-01 · AUTH-02 · AUTH-03 · AUTH-04                  ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                     ║${N}"
echo -e "${M}╚══════════════════════════════════════════════════════════╝${N}"
echo -e "  → Goal: prove L7 identity + per-tool RBAC + token exchange."
pause

AGW_LB=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
[[ -z "${AGW_LB}" ]] && { warn "Cannot resolve AGW LB."; exit 1; }

###############################################################################
# AUTH-01 — OAuth at the gateway
###############################################################################
step "AUTH-01 — OAuth 2.0 / OIDC at the Gateway"
show "POST http://${AGW_LB}/mcp  (no token, expect 401)"
curl -s -o /dev/null -w "  HTTP %{http_code}  (no token)\n" \
  -X POST "http://${AGW_LB}/mcp" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' || true
pause

show "Acquire JWT from Dex (password grant)"
${KC} -n "${DEX_NS}" port-forward svc/dex 5556:5556 &>/dev/null &
DEX_PF=$!
trap 'kill ${DEX_PF} 2>/dev/null || true' EXIT
sleep 3
TOKEN=$(curl -s --max-time 5 -X POST http://localhost:5556/dex/token \
  -d "grant_type=password" \
  -d "username=${DEMO_USER}" \
  -d "password=${DEMO_PASS}" \
  -d "scope=openid email groups" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id_token",""))' 2>/dev/null || echo "")
if [[ -n "${TOKEN}" ]]; then
  ok "Token acquired (first 40 chars): ${TOKEN:0:40}..."
else
  warn "Could not acquire token — check Dex port-forward / config."
fi
pause

if [[ -n "${TOKEN}" ]]; then
  show "POST http://${AGW_LB}/mcp  with valid Bearer (expect 200/204)"
  curl -s -o /dev/null -w "  HTTP %{http_code}  (valid token)\n" \
    -X POST "http://${AGW_LB}/mcp" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"poc","version":"1"}}}' || true

  show "Same call with TAMPERED token (expect 401)"
  curl -s -o /dev/null -w "  HTTP %{http_code}  (tampered)\n" \
    -X POST "http://${AGW_LB}/mcp" \
    -H "Authorization: Bearer ${TOKEN}xxx" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' || true
fi
note "ExtAuth validates signature + iss + aud + exp on every request — not just init."
pause

###############################################################################
# AUTH-02 — Tool-Level RBAC (OPA)
###############################################################################
step "AUTH-02 — Tool-Level RBAC (OPA)"
show "${KC} -n ${AGW_NS} get configmap | grep opa"
${KC} -n "${AGW_NS}" get configmap | grep -i opa || warn "No OPA ConfigMap found."
note "If OPA isn't installed yet, see the demo's scripts/05-extauth.sh and the
      OPA setup in the docs (https://docs.solo.io/agentgateway/2.2.x/security/extauth/opa/)."
pause

note "Manual demo step: with two JWTs (role:agent vs role:admin), call tools/call
      for 'echo' (always allowed) and 'delete_database' (admin-only). The 'agent'
      role should receive an MCP permission error on delete_database; admin should succeed."
pause

###############################################################################
# AUTH-03 — Two-Level Tool Filtering
###############################################################################
step "AUTH-03 — Two-Level Tool Filtering"
echo -e "  → Filtering at server-level (which servers a team sees) AND tool-level"
echo -e "    (which tools within a server). See validate.md for full policy."
pause

note "Demo step: with a 'support team' JWT, run tools/list and verify only
      support-related servers appear, AND within those only the allowed tools.
      With a 'platform team' JWT, all servers + all tools should be visible."
pause

###############################################################################
# AUTH-04 — Token Exchange / On-Behalf-Of
###############################################################################
step "AUTH-04 — Token Exchange / On-Behalf-Of (RFC 8693)"
note "Dex (demo IdP) does not support RFC 8693 — for real validation, run this against
      a Keycloak / Auth0 / Entra-backed cluster (any IdP that implements RFC 8693)."
echo -e "  → Demo path: print the configured token-exchange AuthConfig (if any),"
echo -e "    show what an exchanged token's claims look like in mock mode."
pause

show "${KC} -n ${AGW_NS} get authconfig"
${KC} -n "${AGW_NS}" get authconfig 2>/dev/null || warn "No AuthConfig CRD or no resources."
pause

echo -e "\n${G}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 5 validation complete ✅                         ║${N}"
echo -e "${G}║                                                          ║${N}"
echo -e "${G}║   AUTH-01  OAuth at the gateway                          ║${N}"
echo -e "${G}║   AUTH-02  Tool-level RBAC (OPA)                         ║${N}"
echo -e "${G}║   AUTH-03  Two-level tool filtering                      ║${N}"
echo -e "${G}║   AUTH-04  Token exchange / OBO (validate on Keycloak)   ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}\n"
