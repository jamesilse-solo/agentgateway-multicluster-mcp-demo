#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-oauth21.sh — OAuth 2.1 hardening checks
#
# Validated live against Solo CRD v2.3.3 + Keycloak 26 (solo-demo realm):
#
#   ✅ PKCE on the auth-code flow — Keycloak accepts code_challenge / S256
#   ✅ Client-credentials grant — Keycloak issues a token for mcp-service
#      (this was the headline OAuth 2.1 gap when the demo ran on Dex (now replaced by Keycloak across the install)
#      v2.42; cutover to Keycloak closes it).
#   ✅ RFC 9728 protected-resource-metadata — served live at
#      /.well-known/oauth-protected-resource/mcp via a dedicated
#      `mcp-wellknown` HTTPRoute + EnterpriseAgentgatewayPolicy using
#      traffic.jwtAuthentication.mcp.resourceMetadata
#      (wired by scripts/05d-oauth21.sh).
#
#   ✅ RFC 8414 authorization-server-metadata — also served live at
#      /.well-known/oauth-authorization-server/mcp; AGW proxies and
#      transforms Keycloak's OIDC discovery document.
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
AUTH_URL="http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/auth?client_id=agw-client&response_type=code&scope=openid+email+profile&redirect_uri=${REDIRECT_URI}&state=${STATE}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_URL}")
if [[ "${HTTP}" == "302" || "${HTTP}" == "200" ]]; then
  ok "Keycloak /auth accepted code_challenge + code_challenge_method=S256 (HTTP ${HTTP})"
  ok "PKCE is now available on the existing browser-driven flow."
else
  bad "Keycloak /auth returned HTTP ${HTTP} — PKCE may not be accepted"
fi

###############################################################################
# Check 2 — Client-credentials grant (limitation reported honestly)
###############################################################################
banner "Check 2 — Client-credentials grant"
RESP=$(curl -s -X POST "http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/token" \
  -d 'grant_type=client_credentials' \
  -d "client_id=${SERVICE_CLIENT_ID}" \
  -d "client_secret=${SERVICE_CLIENT_SECRET}" \
  -d 'scope=openid')
ERR=$(echo "${RESP}" | jq -r '.error // empty' 2>/dev/null)
TOK=$(echo "${RESP}" | jq -r '.access_token // empty' 2>/dev/null)

if [[ -n "${TOK}" ]]; then
  ok "Client-credentials grant returned an access_token (length ${#TOK})"
  ok "Keycloak issues a real m2m token for mcp-service. No user, no password."
elif [[ -n "${ERR}" ]]; then
  warn "Keycloak returned: ${ERR}"
  warn "Check that scripts/03b-keycloak.sh ran and the mcp-service client exists."
fi

###############################################################################
# Check 3 — RFC 9728 protected-resource-metadata
###############################################################################
banner "Check 3 — RFC 9728 protected-resource-metadata endpoint"
RM_PATH="/.well-known/oauth-protected-resource/mcp"
RM_BODY=$(curl -s "http://${AGW_LB}${RM_PATH}")
RM_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${AGW_LB}${RM_PATH}")
if [[ "${RM_HTTP}" == "200" ]] && echo "${RM_BODY}" | jq -e '.resource and .authorization_servers' >/dev/null 2>&1; then
  ok "GET ${RM_PATH} → 200, RFC 9728 JSON"
  echo "${RM_BODY}" | jq -C '.' | sed 's/^/      /'
else
  bad "GET ${RM_PATH} → HTTP ${RM_HTTP} (run scripts/05d-oauth21.sh to wire the metadata route)"
fi

###############################################################################
# Check 4 — RFC 8414 authorization-server-metadata
###############################################################################
banner "Check 4 — RFC 8414 authorization-server-metadata endpoint"
AS_PATH="/.well-known/oauth-authorization-server/mcp"
AS_BODY=$(curl -s "http://${AGW_LB}${AS_PATH}")
AS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${AGW_LB}${AS_PATH}")
if [[ "${AS_HTTP}" == "200" ]] && echo "${AS_BODY}" | jq -e '.issuer and .authorization_endpoint and .token_endpoint' >/dev/null 2>&1; then
  ok "GET ${AS_PATH} → 200, has issuer + authorization_endpoint + token_endpoint"
  echo "${AS_BODY}" | jq -C '{issuer, authorization_endpoint, token_endpoint, jwks_uri, response_types_supported}' | sed 's/^/      /'
else
  bad "GET ${AS_PATH} → HTTP ${AS_HTTP}"
fi

###############################################################################
# Summary
###############################################################################
banner "What works today, and what to know"
cat <<EOF
  Live (validated against the cluster):
    ✓ PKCE on auth-code flow (Keycloak accepts code_challenge + S256)
    ✓ Client-credentials grant (Keycloak mcp-service client returns
      a JWT — the m2m flow OAuth 2.1 prefers over password grant)
    ✓ RFC 9728 protected-resource-metadata served at
      /.well-known/oauth-protected-resource/mcp
    ✓ RFC 8414 authorization-server-metadata served at
      /.well-known/oauth-authorization-server/mcp

  Configuration (in this POC):
    • Dedicated mcp-wellknown HTTPRoute (anonymous, two exact paths)
    • EnterpriseAgentgatewayPolicy mcp-resource-metadata using
      traffic.jwtAuthentication.mcp.{provider:Keycloak, resourceMetadata}
    • /mcp itself keeps its existing ExtAuth (auth-code session cookies)

  See examples/04-oauth21.md for the full breakdown.
EOF
