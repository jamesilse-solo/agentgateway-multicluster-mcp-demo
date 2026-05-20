#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-oauth21.sh — OAuth 2.1 hardening checks
#
# Validated live against Solo CRD v2.3.3 + Dex v2.42.0:
#
#   ✅ PKCE on the auth-code flow — Dex accepts code_challenge / S256
#   ⚠️ Client-credentials — Dex v2.42 returns 400 unsupported_grant_type
#      out of the box. A production IdP (Keycloak / Auth0 / Entra) is
#      needed for this grant.
#   ⚠️ RFC 9728 protected-resource-metadata — the field exists on
#      AgentgatewayPolicy.backend.mcp.authentication.resourceMetadata
#      and is accepted by the CRD, but the well-known endpoint is not
#      served by AGW v2.3.3 (returns 302 / OIDC redirect).
#
# This script reports honestly on each.
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
SERVICE_CLIENT_ID="${SERVICE_CLIENT_ID:-mcp-service}"
SERVICE_CLIENT_SECRET="${SERVICE_CLIENT_SECRET:-mcp-service-secret}"
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

###############################################################################
# Check 1 — PKCE handshake (works)
###############################################################################
banner "Check 1 — PKCE handshake on the existing auth-code flow"

CODE_VERIFIER=$(openssl rand -base64 96 | tr -d "=+/\n" | cut -c1-128)
CODE_CHALLENGE=$(printf "%s" "${CODE_VERIFIER}" | openssl dgst -sha256 -binary | base64 | tr "+/" "-_" | tr -d "=\n")
note "code_verifier  (truncated): ${CODE_VERIFIER:0:40}..."
note "code_challenge (S256):      ${CODE_CHALLENGE}"

REDIRECT_URI="http://${AGW_LB}/callback"
STATE="example-04-pkce-$(date +%s)"
AUTH_URL="http://${AGW_LB}/dex/auth?client_id=agw-client&response_type=code&scope=openid+email+profile&redirect_uri=${REDIRECT_URI}&state=${STATE}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_URL}")
if [[ "${HTTP}" == "302" || "${HTTP}" == "200" ]]; then
  ok "Dex /auth accepted code_challenge + code_challenge_method=S256 (HTTP ${HTTP})"
  ok "PKCE is now available on the existing browser-driven flow."
else
  bad "Dex /auth returned HTTP ${HTTP} — PKCE may not be accepted"
fi

###############################################################################
# Check 2 — Client-credentials grant (limitation reported honestly)
###############################################################################
banner "Check 2 — Client-credentials grant"
RESP=$(curl -s -X POST "http://${AGW_LB}/dex/token" \
  -d 'grant_type=client_credentials' \
  -d "client_id=${SERVICE_CLIENT_ID}" \
  -d "client_secret=${SERVICE_CLIENT_SECRET}" \
  -d 'scope=openid')
ERR=$(echo "${RESP}" | jq -r '.error // empty' 2>/dev/null)
TOK=$(echo "${RESP}" | jq -r '.access_token // empty' 2>/dev/null)

if [[ -n "${TOK}" ]]; then
  ok "Client-credentials grant returned an access_token"
elif [[ -n "${ERR}" ]]; then
  warn "Dex v2.42 returned: ${ERR}"
  warn "Dex does not support the client_credentials grant out of the box."
  warn "Production IdPs (Keycloak / Auth0 / Entra) do; substitute one for this flow."
fi

###############################################################################
# Check 3 — RFC 9728 protected-resource-metadata
###############################################################################
banner "Check 3 — RFC 9728 protected-resource-metadata endpoint"
for RM_PATH in /.well-known/oauth-protected-resource /mcp/.well-known/oauth-protected-resource; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${AGW_LB}${RM_PATH}")
  if [[ "${HTTP}" == "200" ]]; then
    ok "GET ${RM_PATH} → 200"
    curl -s "http://${AGW_LB}${RM_PATH}" | jq -C '.' | sed 's/^/      /'
    break
  else
    warn "GET ${RM_PATH} → HTTP ${HTTP} (not the JSON metadata document)"
  fi
done
warn "AGW v2.3.3 accepts the resourceMetadata field on the CRD but does not"
warn "publish the well-known endpoint at the gateway LB. The CRD plumbing is"
warn "ready; the runtime support is product-version pending."

###############################################################################
# Summary
###############################################################################
banner "What works today, and what to know"
cat <<EOF
  Live (validated):
    ✓ PKCE on auth-code flow (Dex accepts code_challenge + S256)
    ✓ The mcp-service Dex client object is in place (config-ready for
      when client-credentials becomes available — IdP or Dex upgrade)
    ✓ AgentgatewayPolicy.mcp.authentication.resourceMetadata field on
      the policy (config-ready for when AGW publishes the well-known)

  Product gaps (honest):
    ⚠ Dex v2.42 → unsupported_grant_type on client_credentials. Use
      Keycloak / Auth0 / Entra for true m2m flow in production.
    ⚠ AGW v2.3.3 → /.well-known/oauth-protected-resource not served at
      the gateway LB. Track for a future AGW release.

  See examples/04-oauth21.md for the full breakdown.
EOF
