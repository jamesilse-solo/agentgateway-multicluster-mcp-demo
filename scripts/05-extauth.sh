#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05-extauth.sh — Authentication via Keycloak OIDC + ExtAuth
#
# Configures ExtAuth + Redis to enforce Keycloak OIDC on the AgentGateway Hub.
# Unauthenticated browser requests receive 302 redirect to Keycloak's login;
# MCP clients use Bearer JWT from Keycloak's token endpoint.
#
# Prerequisites:
#   - 03b-keycloak.sh has run (Keycloak realm + clients + users present)
#   - AgentGateway Enterprise is installed with ExtAuth + ExtCache running
#   - Hub gateway (agentgateway-hub) exists (02-configure.sh)
#
# Usage:
#   export AGENTGATEWAY_LICENSE_KEY=<key>
#   ./05-extauth.sh
###############################################################################

# ─── Required Parameters ─────────────────────────────────────────────────────
: "${AGENTGATEWAY_LICENSE_KEY:?AGENTGATEWAY_LICENSE_KEY is required}"

# ─── Optional Parameters ─────────────────────────────────────────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"

# Keycloak parameters
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"

# Keycloak OAuth client used for browser auth-code + ExtAuth session
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-agw-client}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-agw-client-secret}"

AGW_HELM_REPO="${AGW_HELM_REPO:-us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
AGW_VERSION="${AGW_VERSION:-v2.3.0-rc.3}"

# Get AGW LB address (required — must exist before this script runs)
AGW_LB=$(kubectl --context "${KUBE_CONTEXT}" -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [[ -z "${AGW_LB}" ]]; then
  echo "ERROR: agentgateway-hub LoadBalancer address not yet provisioned. Wait for 04a to complete and retry."
  exit 1
fi

# Keycloak realm URLs (reachable through the AGW LB by 03b-keycloak.sh's routes)
OIDC_BASE="http://${AGW_LB}/realms/${KEYCLOAK_REALM}"
OIDC_ISSUER_URL="${OIDC_BASE}"
DEMO_APP_URL="${DEMO_APP_URL:-http://${AGW_LB}}"

# ─── Helper ───────────────────────────────────────────────────────────────────
KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

log "AgentGateway LB: ${AGW_LB}"
log "Keycloak issuer: ${OIDC_ISSUER_URL}"
log "App URL:         ${DEMO_APP_URL}"

###############################################################################
# 1. Verify ExtAuth + ExtCache are running (deployed by default in AGW chart)
###############################################################################
log "Verifying ExtAuth + ExtCache pods"
${KC} get pods -n "${AGW_NAMESPACE}" -l app=ext-auth-service 2>&1 | grep -E "Running|NAME" || \
  echo "WARNING: ext-auth-service pod not found — AGW may need ExtAuth enabled"
${KC} get pods -n "${AGW_NAMESPACE}" | grep ext-cache || \
  echo "WARNING: ext-cache (Redis) pod not found"

###############################################################################
# 2. Store OAuth client secret (same secret name regardless of IdP)
###############################################################################
log "Storing OAuth client secret"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: oauth-dex
  namespace: ${AGW_NAMESPACE}
type: extauth.solo.io/oauth
stringData:
  client-secret: ${OIDC_CLIENT_SECRET}
EOF

###############################################################################
# 3. Verify Keycloak is reachable through the AGW LB
#
# 03b-keycloak.sh creates `keycloak-backend` + the /realms and /resources
# HTTPRoutes. This script just confirms they exist before wiring ExtAuth.
###############################################################################
if ! ${KC} -n "${AGW_NAMESPACE}" get agentgatewaybackend keycloak-backend >/dev/null 2>&1; then
  echo "ERROR: keycloak-backend not found. Run scripts/03b-keycloak.sh first."
  exit 1
fi
log "Keycloak backend + routes already in place (from 03b-keycloak.sh)"

###############################################################################
# 4. Create AuthConfig (OIDC authorization-code flow)
#
# AuthConfig is the same shape for both IdPs — only issuerUrl differs.
# The resource name stays `oidc-dex` for backward compatibility with the
# existing EnterpriseAgentgatewayPolicy targetRefs.
###############################################################################
log "Creating AuthConfig oidc-dex (issuer: ${OIDC_ISSUER_URL})"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: oidc-dex
  namespace: ${AGW_NAMESPACE}
spec:
  configs:
  - oauth2:
      oidcAuthorizationCode:
        appUrl: "${DEMO_APP_URL}"
        callbackPath: /callback
        clientId: ${OIDC_CLIENT_ID}
        clientSecretRef:
          name: oauth-dex
          namespace: ${AGW_NAMESPACE}
        issuerUrl: "${OIDC_ISSUER_URL}"
        scopes:
        - openid
        - email
        - profile
        session:
          failOnFetchFailure: true
          redis:
            cookieName: oidc-session
            options:
              host: ext-cache-enterprise-agentgateway:6379
        headers:
          idTokenHeader: x-user-token
EOF

log "Waiting for AuthConfig to be accepted"
for i in $(seq 1 30); do
  STATUS=$(${KC} get authconfig oidc-dex -n "${AGW_NAMESPACE}" \
    -o jsonpath='{.status.state}' 2>/dev/null || echo "PENDING")
  if [[ "${STATUS}" == "ACCEPTED" || "${STATUS}" == "Accepted" ]]; then
    echo "  AuthConfig status: ${STATUS}"
    break
  fi
  echo "  AuthConfig status: ${STATUS} (attempt ${i}/30)..."
  sleep 5
done

###############################################################################
# 5. Attach AuthConfig to MCP/UI HTTPRoutes (NOT Gateway-wide)
#
# We cannot target the whole Gateway because /realms/* and /resources/*
# (Keycloak) must remain unauthenticated — otherwise the OAuth login
# redirect would itself require a valid session. Instead we enumerate
# the protected routes by name.
# Routes created in later scripts (06, 08, 09) attach to this policy
# automatically once they exist.
###############################################################################
log "Attaching AuthConfig to MCP/UI HTTPRoutes (keycloak-route excluded)"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: oidc-extauth
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: mcp-route
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: mcp-route-remote
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: areg-mcp-route
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: gloo-mesh-ui-route
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: search-solo-io-route
  traffic:
    entExtAuth:
      authConfigRef:
        name: oidc-dex
        namespace: ${AGW_NAMESPACE}
      backendRef:
        name: ext-auth-service-enterprise-agentgateway
        namespace: ${AGW_NAMESPACE}
        port: 8083
EOF

###############################################################################
# 6. Summary + demo test commands
###############################################################################
log "ExtAuth configuration complete"

TOKEN_PATH="/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
AUTH_PATH="/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth"

echo ""
echo "=== DEMO FLOWS (Keycloak) ==="
echo ""
echo "Issuer / OIDC discovery (reachable from a laptop, no port-forward):"
echo "  ${OIDC_BASE}/.well-known/openid-configuration"
echo ""
echo "--- Flow 1: Browser Login (auth code flow) ---"
echo "  Open in browser: http://${AGW_LB}/mcp"
echo "  → Redirected to login at http://${AGW_LB}${AUTH_PATH}?..."
echo "  → Login with: demo / demo-pass"
echo "  → Redirected back to /callback → session established"
echo "  → MCP tools accessible"
echo ""
echo "--- Flow 2: MCP Client Token (password grant / Bearer) ---"
echo "  TOKEN=\$(curl -s -X POST 'http://${AGW_LB}${TOKEN_PATH}' \\"
echo "    -d 'grant_type=password' \\"
echo "    -d 'username=demo' -d 'password=demo-pass' \\"
echo "    -d 'client_id=${OIDC_CLIENT_ID}' -d 'client_secret=${OIDC_CLIENT_SECRET}' \\"
echo "    -d 'scope=openid email profile' | jq -r '.id_token')"
echo ""
echo "  curl -s -H \"Authorization: Bearer \${TOKEN}\" http://${AGW_LB}/mcp"
echo ""
echo "--- Flow 3: client-credentials m2m grant ---"
echo "  TOKEN=\$(curl -s -X POST 'http://${AGW_LB}${TOKEN_PATH}' \\"
echo "    -d 'grant_type=client_credentials' \\"
echo "    -d 'client_id=mcp-service' -d 'client_secret=mcp-service-secret' \\"
echo "    | jq -r '.access_token')"
echo ""
echo "Resources:"
${KC} get secret oauth-dex -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get agentgatewaybackend keycloak-backend -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get authconfig oidc-dex -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get enterpriseagentgatewaypolicy oidc-extauth -n "${AGW_NAMESPACE}" -o name 2>/dev/null
