#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05f-cel-jwt-route.sh — Dedicated Bearer-only MCP route with CEL on JWT claims
#
# Why a separate route?
#
#   AGW v2026.5.0 cannot compose `traffic.entExtAuth` (browser session via
#   Keycloak/ExtAuth) with `traffic.jwtAuthentication.mcp` (Bearer-only,
#   parses JWT into `jwt.*` for CEL) on the same HTTPRoute. They both
#   claim the Authorization header in incompatible ways; with both
#   attached, Bearer requests to /mcp 302-redirect to the login page
#   instead of authenticating.
#
#   This script carves out a parallel `/secure/mcp` route that uses ONLY
#   `traffic.jwtAuthentication.mcp` (mode: Strict — Bearer required, no
#   browser-session fallback). On that route, `jwt.*` IS available to
#   CEL, so authorization policies like
#
#       backend.mcp.authorization.matchExpressions:
#       - 'jwt.email.contains("@your-company.com")'
#       - 'jwt.groups.exists(g, g == "platform-ai")'
#       - 'jwt.preferred_username != "demo"'
#
#   evaluate correctly and gate which MCP tools the client sees.
#
#   The existing /mcp keeps working unchanged — browser users still get
#   302→Keycloak; MCP clients with a Bearer still get 200.
#
# Strict vs Optional (decision table):
#
#   mode: Strict     reject any request without a valid Bearer.
#                     Use ONLY when there is no entExtAuth on the same
#                     route (this script's case). Bearer-only.
#
#   mode: Optional   accept missing/invalid tokens by falling through to
#                     the next handler. Sounds composable but in
#                     practice ExtAuth still runs after, sees no session
#                     cookie, and 302s. Don't expect Optional to "make
#                     ExtAuth + jwtAuth coexist on one route" — that
#                     combination is broken in v2026.5.0. Use this
#                     script's separate-route pattern instead.
#
# Prerequisites:
#   - 04-areg.sh has run (AGW upgraded to v2026.5.x, registry plumbed)
#   - 05-extauth.sh has run (oidc-extauth + Keycloak realm)
#   - The existing agentgateway-hub Gateway is live
#
# Usage:
#   ./scripts/05f-cel-jwt-route.sh                  # apply
#   ./scripts/05f-cel-jwt-route.sh --cleanup        # remove everything
#
# After apply, test with:
#   AGW_LB=$(kubectl --context cluster1 -n agentgateway-system \
#     get gateway agentgateway-hub -o jsonpath='{.status.addresses[0].value}')
#   TOK=$(curl -s -X POST "http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/token" \
#     -d 'grant_type=password&username=demo&password=demo-pass' \
#     -d 'client_id=agw-client&client_secret=agw-client-secret' \
#     -d 'scope=openid email profile' | jq -r '.id_token')
#   curl -i -H "Authorization: Bearer ${TOK}" -H "Content-Type: application/json" \
#     -H "Accept: application/json, text/event-stream" \
#     -X POST "http://${AGW_LB}/secure/mcp" \
#     -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
#          "params":{"protocolVersion":"2024-11-05","capabilities":{},
#                    "clientInfo":{"name":"t","version":"1"}}}'
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AGW_GATEWAY_NAME="${AGW_GATEWAY_NAME:-agentgateway-hub}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-agw-client}"

# CEL expression. Override at runtime to fit your own claim filter, e.g.:
#   CEL_EXPR='jwt.email.contains("@solo.io")' ./scripts/05f-cel-jwt-route.sh
# Default matches the demo user (email=demo@example.com) so the script
# is verifiable on a fresh cluster.
CEL_EXPR="${CEL_EXPR:-jwt.email.contains(\"@example.com\")}"

ROUTE_PATH_PREFIX="${ROUTE_PATH_PREFIX:-/secure/mcp}"
MCP_SVC_NAME="${MCP_SVC_NAME:-mcp-server-everything}"

KC="kubectl --context ${KUBE_CONTEXT}"
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
log()  { echo ""; echo -e "${B}=== $* ===${N}"; }
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
bad()  { echo -e "  ${R}✗${N} $*"; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing CEL-on-JWT route + policies"
  ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaypolicy mcp-secure-cel --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete enterpriseagentgatewaypolicy mcp-secure-jwt --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete httproute mcp-secure-route --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaybackend mcp-secure-backends --ignore-not-found
  ok "Cleanup complete"
  exit 0
fi

# Sanity
${KC} -n "${AGW_NAMESPACE}" get gateway "${AGW_GATEWAY_NAME}" >/dev/null 2>&1 \
  || { bad "Gateway ${AGW_NAMESPACE}/${AGW_GATEWAY_NAME} not found — run 02-configure.sh first"; exit 1; }

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway "${AGW_GATEWAY_NAME}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
OIDC_ISSUER_URL="http://${AGW_LB}/realms/${KEYCLOAK_REALM}"
JWKS_PATH="/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"

log "Applying mcp-secure-backends + mcp-secure-route (PathPrefix ${ROUTE_PATH_PREFIX})"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-secure-backends
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    targets:
    - name: mcp-server-everything-secure
      selector:
        services:
          matchLabels:
            app: ${MCP_SVC_NAME}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-secure-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: ${AGW_GATEWAY_NAME}
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${ROUTE_PATH_PREFIX}
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-secure-backends
      namespace: ${AGW_NAMESPACE}
EOF
ok "backend + route applied"

log "Applying EnterpriseAgentgatewayPolicy mcp-secure-jwt (Strict jwtAuthentication.mcp)"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-secure-jwt
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: mcp-secure-route
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
      - issuer: ${OIDC_ISSUER_URL}
        audiences:
        - ${OIDC_CLIENT_ID}
        jwks:
          remote:
            backendRef:
              kind: Service
              name: keycloak
              namespace: ${KEYCLOAK_NAMESPACE}
              port: 8080
            jwksPath: ${JWKS_PATH}
            cacheDuration: 5m
      mcp:
        provider: Keycloak
EOF
ok "jwtAuthentication policy applied"

log "Applying AgentgatewayPolicy mcp-secure-cel  (CEL: ${CEL_EXPR})"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mcp-secure-cel
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: mcp-secure-backends
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
          - '${CEL_EXPR}'
EOF
ok "CEL policy applied"

# Wait for AcceptedAndAttached on both policies
sleep 4
for P in "enterpriseagentgatewaypolicy/mcp-secure-jwt" "agentgatewaypolicy/mcp-secure-cel"; do
  STATUS=$(${KC} -n "${AGW_NAMESPACE}" get "${P}" -o json 2>/dev/null \
    | jq -r '.status.ancestors[0].conditions[] | select(.type=="Attached") | .status' | head -1)
  if [[ "${STATUS}" == "True" ]]; then
    ok "${P} attached"
  else
    warn "${P} status=${STATUS} — recheck with: ${KC} -n ${AGW_NAMESPACE} get ${P} -o yaml"
  fi
done

log "Done"
cat <<EOF

Route is live at:
  http://${AGW_LB}${ROUTE_PATH_PREFIX}

Bearer-only (Strict). No browser-session fallback.
CEL gate: ${CEL_EXPR}

Live test:
  TOK=\$(curl -s -X POST "http://${AGW_LB}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \\
    -d 'grant_type=password&username=demo&password=demo-pass' \\
    -d 'client_id=${OIDC_CLIENT_ID}&client_secret=agw-client-secret' \\
    -d 'scope=openid email profile' | jq -r '.id_token')
  curl -i -H "Authorization: Bearer \${TOK}" \\
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \\
    -X POST "http://${AGW_LB}${ROUTE_PATH_PREFIX}" \\
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
         "params":{"protocolVersion":"2024-11-05","capabilities":{},
                   "clientInfo":{"name":"t","version":"1"}}}'

To narrow the CEL gate to a specific domain:
  CEL_EXPR='jwt.email.contains("@solo.io")' ./scripts/05f-cel-jwt-route.sh

To remove everything this script applied:
  ./scripts/05f-cel-jwt-route.sh --cleanup
EOF
