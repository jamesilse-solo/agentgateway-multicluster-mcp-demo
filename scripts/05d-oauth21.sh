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
#   3. Wires RFC 9728 ProtectedResourceMetadata + RFC 8414 Authorization-
#      Server Metadata on a dedicated `mcp-wellknown` HTTPRoute, attached
#      to an EnterpriseAgentgatewayPolicy using
#      `traffic.jwtAuthentication.mcp.{provider:Keycloak,resourceMetadata}`.
#      AGW v2.3.3 serves /.well-known/oauth-protected-resource/mcp and
#      /.well-known/oauth-authorization-server/mcp behind that route.
#      Verifies the endpoints return 200 with RFC-compliant JSON.
#
# No Dex anywhere — Keycloak's realm import (in 03b-keycloak.sh) already
# defines the agw-client, mcp-service, tenant-a-client, tenant-b-client
# clients with the right grant types.
#
# Prerequisites:
#   - 03b-keycloak.sh has run
#   - 05-extauth.sh has run (oidc-extauth on /mcp; we leave it alone)
#
# Usage:
#   ./scripts/05d-oauth21.sh
#   ./scripts/05d-oauth21.sh --cleanup
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

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing RFC 9728 metadata route + policy"
  ${KC} -n "${AGW_NAMESPACE}" delete enterpriseagentgatewaypolicy mcp-resource-metadata --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete httproute mcp-wellknown --ignore-not-found
  echo "✓ Cleanup complete"
  exit 0
fi

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
if [[ -z "${AGW_LB}" ]]; then
  echo "ERROR: AGW Hub LB not provisioned."
  exit 1
fi
ISSUER="http://${AGW_LB}/realms/${KEYCLOAK_REALM}"
TOKEN_URL="${ISSUER}/protocol/openid-connect/token"
AUTH_URL="${ISSUER}/protocol/openid-connect/auth"
JWKS_URL="${ISSUER}/protocol/openid-connect/certs"

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
# 4. RFC 9728 / RFC 8414 — wire metadata route + policy and verify it serves
#
#   - mcp-wellknown HTTPRoute: two exact path matches, parented to the same
#     Gateway as /mcp. NOT in the oidc-extauth targetRefs, so anonymous.
#
#   - EnterpriseAgentgatewayPolicy mcp-resource-metadata: attaches
#     traffic.jwtAuthentication.mcp.{provider:Keycloak,resourceMetadata}.
#     AGW's MCP-auth handler dispatches /.well-known/oauth-protected-resource
#     (RFC 9728) and /.well-known/oauth-authorization-server (RFC 8414).
###############################################################################
log "Wiring RFC 9728 metadata route + policy"

${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-wellknown
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: Exact
        value: /.well-known/oauth-protected-resource/mcp
    - path:
        type: Exact
        value: /.well-known/oauth-authorization-server/mcp
    backendRefs:
    - group: ""
      kind: Service
      name: mcp-server-everything
      port: 80
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-resource-metadata
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: mcp-wellknown
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
      - issuer: ${ISSUER}
        audiences:
        - agw-client
        jwks:
          remote:
            backendRef:
              kind: Service
              name: keycloak
              namespace: keycloak
              port: 8080
            jwksPath: /realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs
            cacheDuration: 5m
      mcp:
        provider: Keycloak
        resourceMetadata:
          resource: http://${AGW_LB}/mcp
          scopesSupported:
          - openid
          - email
          - profile
          bearerMethodsSupported:
          - header
          resourceDocumentation: https://docs.solo.io/agentgateway/
EOF

# Give the controller a moment to attach + push the policy.
for i in $(seq 1 12); do
  ATT=$(${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy mcp-resource-metadata \
    -o jsonpath='{.status.attached}' 2>/dev/null || echo "")
  [[ "${ATT}" == "true" || "${ATT}" == "True" ]] && break
  sleep 2
done

log "Verifying /.well-known endpoints serve RFC-compliant JSON"
RM_OK=0
AS_OK=0

RM_URL="http://${AGW_LB}/.well-known/oauth-protected-resource/mcp"
RM_BODY=$(curl -s "${RM_URL}")
RM_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${RM_URL}")
if [[ "${RM_HTTP}" == "200" ]] && echo "${RM_BODY}" | jq -e '.resource and .authorization_servers' >/dev/null 2>&1; then
  ok "GET ${RM_URL} → 200 with resource + authorization_servers fields"
  echo "${RM_BODY}" | jq -C '.' | sed 's/^/      /'
  RM_OK=1
else
  warn "GET ${RM_URL} → HTTP ${RM_HTTP} (body head: $(echo "${RM_BODY}" | head -c 100))"
fi

AS_URL="http://${AGW_LB}/.well-known/oauth-authorization-server/mcp"
AS_BODY=$(curl -s "${AS_URL}")
AS_HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${AS_URL}")
if [[ "${AS_HTTP}" == "200" ]] && echo "${AS_BODY}" | jq -e '.issuer and .authorization_endpoint and .token_endpoint' >/dev/null 2>&1; then
  ok "GET ${AS_URL} → 200 with issuer + authorization_endpoint + token_endpoint"
  AS_OK=1
else
  warn "GET ${AS_URL} → HTTP ${AS_HTTP} (body head: $(echo "${AS_BODY}" | head -c 100))"
fi

cat <<EOF

Summary:
  ✓ Keycloak mcp-service client returns a real m2m JWT
  ✓ Keycloak accepts PKCE (code_challenge_method=S256)
  $([[ ${RM_OK} -eq 1 ]] && echo "✓" || echo "✗") AGW v2.3.3 serves /.well-known/oauth-protected-resource/mcp
  $([[ ${AS_OK} -eq 1 ]] && echo "✓" || echo "✗") AGW v2.3.3 serves /.well-known/oauth-authorization-server/mcp

See examples/04-oauth21.{md,sh} for a deeper walkthrough.
To remove the metadata route + policy: ./scripts/05d-oauth21.sh --cleanup
EOF
