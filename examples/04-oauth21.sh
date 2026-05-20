#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-oauth21.sh — Demonstrate the OAuth 2.1 hardening pieces
#
# Three checks:
#   1. RFC 9728 protected-resource-metadata is publicly fetchable.
#   2. Client-credentials grant works and the token is accepted by /mcp.
#   3. Authorization-code flow with PKCE — generate code_verifier +
#      code_challenge, walk the redirect, exchange the code (informational
#      step — Dex's login is browser-driven; we just prove the metadata
#      and challenge are accepted).
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
bad()    { echo -e "  \033[1;31m✗ $*${N}"; }

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

###############################################################################
# Check 1 — RFC 9728 metadata document
###############################################################################
banner "Check 1 — RFC 9728 protected-resource-metadata"
RM=$(curl -si "http://${AGW_LB}/.well-known/oauth-protected-resource")
STATUS=$(echo "${RM}" | head -1 | awk '{print $2}')
if [[ "${STATUS}" == "200" ]]; then
  ok "GET /.well-known/oauth-protected-resource → 200"
  BODY=$(echo "${RM}" | awk 'BEGIN{b=0} /^\r?$/{b=1;next} b{print}')
  echo "${BODY}" | jq -C '.' 2>/dev/null | sed 's/^/      /' || echo "      ${BODY}"
else
  bad "metadata endpoint returned HTTP ${STATUS}"
  echo "      (Did you run scripts/05d-oauth21.sh? In some AGW builds the resource"
  echo "       metadata endpoint requires the gateway's mcp.authentication field"
  echo "       to be configured exactly — check 'kubectl logs deploy/agentgateway-hub')"
fi

###############################################################################
# Check 2 — Client-credentials grant
###############################################################################
banner "Check 2 — Client-credentials grant (OAuth 2.1 m2m flow)"
note "POST /dex/token with grant_type=client_credentials..."
CC_TOKEN=$(curl -s -X POST "http://${AGW_LB}/dex/token" \
  -d 'grant_type=client_credentials' \
  -d "client_id=${SERVICE_CLIENT_ID}" \
  -d "client_secret=${SERVICE_CLIENT_SECRET}" \
  -d 'scope=openid' | jq -r '.access_token // empty')
if [[ -n "${CC_TOKEN}" ]]; then
  ok "client-credentials token acquired (length ${#CC_TOKEN})"
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${AGW_LB}/mcp" \
    -H "Authorization: Bearer ${CC_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"04","version":"1"}}}')
  [[ "${HTTP}" == "200" ]] && ok "/mcp accepted client-credentials token: HTTP ${HTTP}" \
    || bad "/mcp rejected client-credentials token: HTTP ${HTTP}"
else
  bad "client-credentials grant returned no access_token"
fi

###############################################################################
# Check 3 — PKCE handshake (we only verify the challenge is accepted by /dex/auth)
###############################################################################
banner "Check 3 — PKCE handshake (code_challenge accepted)"

# Generate code_verifier + S256 code_challenge per RFC 7636
CODE_VERIFIER=$(openssl rand -base64 96 | tr -d "=+/\n" | cut -c1-128)
CODE_CHALLENGE=$(printf "%s" "${CODE_VERIFIER}" | openssl dgst -sha256 -binary | base64 | tr "+/" "-_" | tr -d "=\n")
note "code_verifier  (truncated): ${CODE_VERIFIER:0:40}..."
note "code_challenge (S256):      ${CODE_CHALLENGE}"

REDIRECT_URI="http://${AGW_LB}/callback"
STATE="example-04-pkce-$(date +%s)"
AUTH_URL="http://${AGW_LB}/dex/auth?client_id=agw-client&response_type=code&scope=openid+email+profile&redirect_uri=${REDIRECT_URI}&state=${STATE}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256"

HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_URL}")
if [[ "${HTTP}" == "302" || "${HTTP}" == "200" ]]; then
  ok "GET /dex/auth?...&code_challenge=...&code_challenge_method=S256 → HTTP ${HTTP}"
  ok "(Dex accepted the PKCE challenge. Full code-exchange would happen in"
  ok " a browser — see examples/04-oauth21.md for the manual walkthrough.)"
else
  bad "Dex /auth returned HTTP ${HTTP}"
fi

banner "What just happened"
cat <<EOF
  1. The gateway publishes RFC 9728 protected-resource-metadata at
     /.well-known/oauth-protected-resource — MCP clients can discover the
     auth server without out-of-band configuration.
  2. A new Dex client mcp-service supports OAuth 2.1's preferred m2m
     flow (client_credentials). A service-account-style agent gets a
     token with no username/password.
  3. The browser auth-code flow now accepts PKCE (code_challenge +
     code_challenge_method=S256). Dex enforces it when present.

What is NOT done (deliberately, to keep send-traffic.sh working):
  - Password grant is still enabled on the agw-client. Production builds
    should set passwordConnector: null and enablePasswordDB: false.
  - Refresh-token rotation is not configured — out of scope for this
    example.
EOF
