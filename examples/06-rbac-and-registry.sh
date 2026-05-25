#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 06-rbac-and-registry.sh — Multi-tenancy RBAC: cross-tenant calls blocked
#
# After scripts/05e-rbac-strict.sh runs, each tenant route is wired to its
# OWN AuthConfig with validAudiences pinned to the tenant's Keycloak client.
# A tenant-a JWT carries aud=tenant-a-client; a tenant-b JWT carries
# aud=tenant-b-client. The gateway's ExtAuth rejects cross-tenant calls.
#
# 4-cell matrix:
#                    /mcp/tenant-a              /mcp/tenant-b
#   tenant-a JWT     200 (same tenant)          401 (audience mismatch)
#   tenant-b JWT     401 (audience mismatch)    200 (same tenant)
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"
KC="kubectl --context ${KUBE_CONTEXT}"

G='\033[1;32m'; Y='\033[1;33m'; M='\033[0;35m'; N='\033[0m'
banner() { echo -e "\n${M}━━━ $* ━━━${N}"; }
ok()     { echo -e "  ${G}✓ $*${N}"; }
warn()   { echo -e "  ${Y}⚠ $*${N}"; }
bad()    { echo -e "  \033[1;31m✗ $*${N}"; }

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
TOKEN_URL="http://${AGW_LB}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"

get_token() {
  curl -s -X POST "${TOKEN_URL}" \
    -d 'grant_type=password' \
    -d "username=$1" -d "password=$2" \
    -d "client_id=$3" -d "client_secret=$4" \
    -d 'scope=openid email profile' | jq -r '.id_token // empty'
}

show_claims() {
  python3 -c "
import sys,base64,json
s='$1'.split('.')[1]
s += '=' * (-len(s) % 4)
d = json.loads(base64.urlsafe_b64decode(s))
print('    preferred_username:', d.get('preferred_username'))
print('    aud:', d.get('aud'))
print('    azp:', d.get('azp'))
print('    team:', d.get('team', '(none)'))
"
}

init_status() {
  curl -s -o /dev/null -w "%{http_code}" -X POST "http://${AGW_LB}$1" \
    -H "Authorization: Bearer $2" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"06","version":"1"}}}'
}

banner "Step 1 — Acquire one JWT per tenant client"
TOKEN_A=$(get_token tenant-a-agent tenant-a-pass tenant-a-client tenant-a-client-secret)
TOKEN_B=$(get_token tenant-b-agent tenant-b-pass tenant-b-client tenant-b-client-secret)
[[ -z "${TOKEN_A}" ]] && { bad "tenant-a token failed"; exit 1; }
[[ -z "${TOKEN_B}" ]] && { bad "tenant-b token failed"; exit 1; }

ok "tenant-a token claims:"
show_claims "${TOKEN_A}"
ok "tenant-b token claims:"
show_claims "${TOKEN_B}"

banner "Step 2 — Same-tenant calls (expect 200)"
HTTP=$(init_status /mcp/tenant-a "${TOKEN_A}")
[[ "${HTTP}" == "200" ]] && ok "tenant-a → /mcp/tenant-a: HTTP ${HTTP}" || bad "tenant-a → /mcp/tenant-a: HTTP ${HTTP}"
HTTP=$(init_status /mcp/tenant-b "${TOKEN_B}")
[[ "${HTTP}" == "200" ]] && ok "tenant-b → /mcp/tenant-b: HTTP ${HTTP}" || bad "tenant-b → /mcp/tenant-b: HTTP ${HTTP}"

banner "Step 3 — Cross-tenant calls (expect 401/302, NOT 200)"
HTTP=$(init_status /mcp/tenant-b "${TOKEN_A}")
if [[ "${HTTP}" == "401" || "${HTTP}" == "403" || "${HTTP}" == "302" ]]; then
  ok "tenant-a → /mcp/tenant-b: HTTP ${HTTP} (blocked at gateway)"
else
  bad "tenant-a → /mcp/tenant-b: HTTP ${HTTP} (CROSS-TENANT LEAKED THROUGH!)"
fi
HTTP=$(init_status /mcp/tenant-a "${TOKEN_B}")
if [[ "${HTTP}" == "401" || "${HTTP}" == "403" || "${HTTP}" == "302" ]]; then
  ok "tenant-b → /mcp/tenant-a: HTTP ${HTTP} (blocked at gateway)"
else
  bad "tenant-b → /mcp/tenant-a: HTTP ${HTTP} (CROSS-TENANT LEAKED THROUGH!)"
fi

banner "What just happened"
cat <<EOF
  • Each tenant logs in via its OWN Keycloak client. Keycloak issues a
    JWT with that client as the audience claim.
  • Each tenant HTTPRoute on the gateway is bound to its OWN AuthConfig
    via EnterpriseAgentgatewayPolicy. Each AuthConfig's clientId pins
    the expected audience.
  • Same-tenant calls authenticate cleanly (200).
  • Cross-tenant calls — a tenant-a JWT hitting /mcp/tenant-b — are
    blocked at ExtAuth BEFORE reaching the upstream MCP server.

This is the multi-tenancy RBAC enforcement loop:
  identity → audience claim → per-tenant AuthConfig → cross-tenant block

The Visible Identity console (/console/) renders the team claim from
each tenant's JWT, so you can SEE which tenant is logged in and which
tools they have access to.

To revert: ./scripts/05e-rbac-strict.sh --cleanup
EOF
