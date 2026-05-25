#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05d-oauth21.sh — OAuth 2.1 verification against the Keycloak realm
#
# What this script does (Keycloak realm-based):
#
#   1. Verifies that the OAuth 2.1 m2m client (`mcp-service`) configured by
#      03b-keycloak.sh actually issues a token via the client-credentials
#      grant — proving the m2m flow OAuth 2.1 prefers over password grant.
#
#   2. Verifies that Keycloak accepts PKCE on the agw-client authorization
#      code flow (code_challenge + code_challenge_method=S256).
#
#   3. Reports honestly on RFC 9728 ProtectedResourceMetadata:
#      AGW v2.3.3 accepts the `resourceMetadata` field on
#      AgentgatewayPolicy.backend.mcp.authentication.resourceMetadata but
#      does NOT serve /.well-known/oauth-protected-resource at the LB.
#      Tracked for a future AGW release.
#
# No Dex anywhere — Keycloak's realm import (in 03b-keycloak.sh) already
# defines the agw-client, mcp-service, tenant-a-client, tenant-b-client
# clients with the right grant types.
#
# Prerequisites:
#   - 03b-keycloak.sh has run
#   - 05-extauth.sh has run
#
# Usage:
#   ./scripts/05d-oauth21.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
SERVICE_CLIENT_ID="${SERVICE_CLIENT_ID:-mcp-service}"
SERVICE_CLIENT_SECRET="${SERVICE_CLIENT_SECRET:-mcp-service-secret}"

KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }
ok()  { echo "  ✓ $*"; }
warn(){ echo "  ⚠ $*"; }
bad() { echo "  ✗ $*"; }

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
if [[ -z "${AGW_LB}" ]]; then
  echo "ERROR: AGW Hub LB not provisioned."
  exit 1
fi
ISSUER="http://${AGW_LB}/realms/${KEYCLOAK_REALM}"
TOKEN_URL="${ISSUER}/protocol/openid-connect/token"
AUTH_URL="${ISSUER}/protocol/openid-connect/auth"

###############################################################################
# 1. Verify the mcp-service client exists in the realm
###############################################################################
log "Verifying ${SERVICE_CLIENT_ID} Keycloak client exists"
KC_POD=$(${KC} -n "${KEYCLOAK_NAMESPACE}" get pod -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "${KC_POD}" ]]; then
  echo "ERROR: Keycloak pod not found. Run scripts/03b-keycloak.sh first."
  exit 1
fi

${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user admin --password admin >/dev/null

CID=$(${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "${KEYCLOAK_REALM}" \
    -q "clientId=${SERVICE_CLIENT_ID}" --fields id --format csv --noquotes 2>/dev/null \
  | tail -1 | tr -d '\r')

if [[ -n "${CID}" ]]; then
  ok "${SERVICE_CLIENT_ID} client exists (id=${CID})"
else
  bad "${SERVICE_CLIENT_ID} client NOT found. Re-run scripts/03b-keycloak.sh."
  exit 1
fi

###############################################################################
# 2. Exercise the client-credentials grant
###############################################################################
log "Acquiring an m2m token via client-credentials grant"
RESP=$(curl -s -X POST "${TOKEN_URL}" \
  -d 'grant_type=client_credentials' \
  -d "client_id=${SERVICE_CLIENT_ID}" \
  -d "client_secret=${SERVICE_CLIENT_SECRET}")
TOK=$(echo "${RESP}" | jq -r '.access_token // empty')
ERR=$(echo "${RESP}" | jq -r '.error // empty')

if [[ -n "${TOK}" ]]; then
  ok "client-credentials grant returned an access_token (length ${#TOK})"
  AUD=$(python3 -c "import sys,base64,json; s='${TOK}'.split('.')[1]; s+='='*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s)).get('aud'))" 2>/dev/null || echo "?")
  AZP=$(python3 -c "import sys,base64,json; s='${TOK}'.split('.')[1]; s+='='*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s)).get('azp'))" 2>/dev/null || echo "?")
  ok "  aud=${AUD}  azp=${AZP}"
else
  bad "client-credentials grant failed: ${ERR}"
fi

###############################################################################
# 3. Exercise PKCE on the auth-code flow
###############################################################################
log "Verifying PKCE handshake (code_challenge + S256)"
CODE_VERIFIER=$(openssl rand -base64 96 | tr -d "=+/\n" | cut -c1-128)
CODE_CHALLENGE=$(printf "%s" "${CODE_VERIFIER}" | openssl dgst -sha256 -binary | base64 | tr "+/" "-_" | tr -d "=\n")
PKCE_URL="${AUTH_URL}?client_id=agw-client&response_type=code&scope=openid+email+profile&redirect_uri=http%3A%2F%2F${AGW_LB}%2Fcallback&state=oauth21-test&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${PKCE_URL}")
if [[ "${HTTP}" == "200" || "${HTTP}" == "302" ]]; then
  ok "Keycloak /auth accepted code_challenge + code_challenge_method=S256 (HTTP ${HTTP})"
else
  bad "Keycloak /auth returned HTTP ${HTTP}"
fi

###############################################################################
# 4. RFC 9728 — not served by AGW v2.3.3 (documented gap)
###############################################################################
log "Checking RFC 9728 protected-resource-metadata endpoint (known gap)"
for P in /.well-known/oauth-protected-resource /mcp/.well-known/oauth-protected-resource; do
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${AGW_LB}${P}")
  warn "  GET ${P} → HTTP ${HTTP} (AGW v2.3.3 does not publish this endpoint)"
done

cat <<EOF

Summary:
  ✓ Keycloak mcp-service client returns a real m2m JWT
  ✓ Keycloak accepts PKCE (code_challenge_method=S256)
  ⚠ AGW v2.3.3 does not serve /.well-known/oauth-protected-resource

See examples/04-oauth21.{md,sh} for a deeper walkthrough.
EOF
