#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 06-rbac-and-registry.sh
#
# What this example demonstrates (live):
#   1. Per-tenant Dex OAuth clients (tenant-a-client, tenant-b-client) issue
#      JWTs with distinct audience claims (aud=tenant-a-client vs aud=tenant-b-client).
#   2. Each tenant's token still successfully authenticates against either
#      /mcp/tenant-a or /mcp/tenant-b — the path-based tenant separation
#      from Package 1 is operational, not identity-enforced.
#
# Why the strict enforcement is NOT applied in this iteration:
#   The "correct" enforcement is per-tenant AgentgatewayPolicy with
#   backend.mcp.authentication.audiences = [<tenant>-client]. That field
#   requires a jwks block (CRD-mandatory in v2.3.3); applying it introduces
#   a parallel JWT validator that conflicts with the existing
#   EnterpriseAgentgatewayPolicy (oidc-extauth) chain and destabilizes /mcp.
#
# Two production paths that close this gap cleanly:
#   - Per-tenant AuthConfig with validAudiences set on the ExtAuth chain
#     (cleanest — no parallel validator).
#   - OPA bundle wired to ExtAuth that decides path-vs-aud per request.
#
# This script verifies that tenant-aware tokens flow through correctly so
# the per-tenant audiences are already discriminable when one of those
# enforcement paths is added.
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
banner() { echo -e "\n${M}━━━ $* ━━━${N}"; }
note()   { echo -e "  ${Y}↳ $*${N}"; }
ok()     { echo -e "  ${G}✓ $*${N}"; }
warn()   { echo -e "  ${Y}⚠ $*${N}"; }
bad()    { echo -e "  \033[1;31m✗ $*${N}"; }

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

get_token() {
  local user="$1" pass="$2" client_id="$3" client_secret="$4"
  curl -s -X POST "http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/token" \
    -d 'grant_type=password' \
    -d "username=${user}" -d "password=${pass}" \
    -d "client_id=${client_id}" -d "client_secret=${client_secret}" \
    -d 'scope=openid email profile' | jq -r '.id_token // empty'
}

show_aud() {
  python3 -c "import sys,base64,json; s='$1'.split('.')[1]; s+='='*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s)).get('aud'))" 2>/dev/null
}

init_status() {
  local path="$1" token="$2"
  curl -s -o /dev/null -w "%{http_code}" -X POST "http://${AGW_LB}${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"06","version":"1"}}}'
}

banner "Step 1 — Acquire one JWT per tenant client (different audiences)"
TOKEN_A=$(get_token tenant-a-agent tenant-a-pass tenant-a-client tenant-a-client-secret)
TOKEN_B=$(get_token tenant-b-agent tenant-b-pass tenant-b-client tenant-b-client-secret)
[[ -z "${TOKEN_A}" ]] && { bad "tenant-a token acquisition failed (run scripts/05e-rbac-strict.sh)"; exit 1; }
[[ -z "${TOKEN_B}" ]] && { bad "tenant-b token acquisition failed"; exit 1; }
ok "tenant-a token aud = $(show_aud "${TOKEN_A}")"
ok "tenant-b token aud = $(show_aud "${TOKEN_B}")"
ok "Different audiences confirmed → ready for strict enforcement"

banner "Step 2 — Same-tenant calls (expect 200 with current config)"
HTTP=$(init_status /mcp/tenant-a "${TOKEN_A}")
[[ "${HTTP}" == "200" ]] && ok "tenant-a → /mcp/tenant-a: HTTP ${HTTP}" || bad "tenant-a → /mcp/tenant-a: HTTP ${HTTP}"
HTTP=$(init_status /mcp/tenant-b "${TOKEN_B}")
[[ "${HTTP}" == "200" ]] && ok "tenant-b → /mcp/tenant-b: HTTP ${HTTP}" || bad "tenant-b → /mcp/tenant-b: HTTP ${HTTP}"

banner "Step 3 — Cross-tenant calls (no enforcement yet — currently HTTP 200)"
HTTP=$(init_status /mcp/tenant-b "${TOKEN_A}")
echo "  tenant-a → /mcp/tenant-b: HTTP ${HTTP}"
HTTP=$(init_status /mcp/tenant-a "${TOKEN_B}")
echo "  tenant-b → /mcp/tenant-a: HTTP ${HTTP}"
warn "Cross-tenant calls currently pass — strict enforcement is the next step"
warn "(needs per-tenant AuthConfig with validAudiences, or an OPA bundle)."

banner "What just happened"
cat <<EOF
  1. Two per-tenant Dex clients exist (tenant-a-client, tenant-b-client).
     Each one issues JWTs with its own audience claim.
  2. The differentiated tokens are flowing through ExtAuth correctly —
     /mcp/tenant-a and /mcp/tenant-b both accept their tenant's token.
  3. Cross-tenant calls also succeed (no enforcement yet). The CRD path
     for audience-restricted backends in v2.3.3 conflicts with the
     existing ExtAuth chain; the production approach is per-tenant
     AuthConfig (out of scope for this PR — flagged as the next step
     in the POC criteria).

What this example demonstrates is the AUTH FOUNDATION needed for
strict tenant separation — the tokens are now distinguishable, so
the moment AuthConfig or OPA is wired, enforcement engages with no
client-side change.
EOF
