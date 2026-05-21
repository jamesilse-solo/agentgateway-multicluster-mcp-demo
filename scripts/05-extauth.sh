#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05-extauth.sh — Authentication (Flow 1: User Auth via Dex OIDC ExtAuth)
#
# Implements Flow 1 (User Auth): configures ExtAuth + Redis to enforce Dex
# OIDC on the AgentGateway Hub.
# Unauthenticated browser requests receive 302 redirect to Dex login;
# MCP clients use Bearer JWT from Dex.
#
# For Flow 2 (MCP Auth with dynamic discovery) see the README — requires
# Keycloak or Auth0 (Dex does not support MCP OAuth dynamic client registration).
#
# Prerequisites:
#   - 03-dex.sh has run (Dex is deployed and running)
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

# IDP selector: keycloak (default, recommended) or dex (legacy)
IDP="${IDP:-keycloak}"

# Dex (legacy) parameters
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"

# Keycloak parameters
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"

# Shared OAuth client (same client name across IdPs for portability)
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

# Resolve the IdP-specific issuer / discovery / JWKS / token URLs.
case "${IDP}" in
  keycloak)
    OIDC_BASE="http://${AGW_LB}/realms/${KEYCLOAK_REALM}"
    OIDC_ISSUER_URL="${OIDC_BASE}"
    IDP_NAMESPACE="${KEYCLOAK_NAMESPACE}"
    IDP_BACKEND_NAME="keycloak-backend"
    IDP_SVC_HOST="keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local"
    IDP_SVC_PORT="8080"
    IDP_LB_PATH_PREFIX="/realms"
    ;;
  dex)
    OIDC_BASE="http://${AGW_LB}/dex"
    OIDC_ISSUER_URL="${OIDC_BASE}/"
    IDP_NAMESPACE="${DEX_NAMESPACE}"
    IDP_BACKEND_NAME="dex-backend"
    IDP_SVC_HOST="dex.${DEX_NAMESPACE}.svc.cluster.local"
    IDP_SVC_PORT="5556"
    IDP_LB_PATH_PREFIX="/dex"
    ;;
  *)
    echo "ERROR: IDP must be 'keycloak' or 'dex' (got '${IDP}')"
    exit 1
    ;;
esac

DEMO_APP_URL="${DEMO_APP_URL:-http://${AGW_LB}}"

# ─── Helper ───────────────────────────────────────────────────────────────────
KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

log "AgentGateway LB: ${AGW_LB}"
log "IDP:             ${IDP}"
log "Issuer URL:      ${OIDC_ISSUER_URL}"
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
# 3. AgentgatewayBackend + HTTPRoute that expose the IdP via the AGW LB
#
# For Keycloak (IDP=keycloak): 03b-keycloak.sh already created
# `keycloak-backend` and the /realms + /resources HTTPRoutes. We just
# verify they exist.
# For Dex (IDP=dex, legacy): we create the backend + /dex HTTPRoute and
# patch Dex's configmap to use the external issuer.
###############################################################################
if [[ "${IDP}" == "dex" ]]; then
  log "Creating AgentgatewayBackend + /dex HTTPRoute for Dex"
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ${IDP_BACKEND_NAME}
  namespace: ${AGW_NAMESPACE}
spec:
  static:
    host: ${IDP_SVC_HOST}
    port: ${IDP_SVC_PORT}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${IDP}-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${IDP_LB_PATH_PREFIX}
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: ${IDP_BACKEND_NAME}
      namespace: ${AGW_NAMESPACE}
EOF

  log "Patching Dex configmap to use external issuer: ${OIDC_BASE}"
  CURRENT_CONFIG=$(${KC} -n "${IDP_NAMESPACE}" get configmap dex-config \
    -o jsonpath='{.data.config\.yaml}')
  NEW_CONFIG=$(echo "${CURRENT_CONFIG}" \
    | sed -E "s|^issuer:.*|issuer: ${OIDC_BASE}|")
  ${KC} -n "${IDP_NAMESPACE}" create configmap dex-config \
    --from-literal=config.yaml="${NEW_CONFIG}" \
    --dry-run=client -o yaml | ${KC} apply -f -
  ${KC} -n "${IDP_NAMESPACE}" rollout restart deployment/dex
  ${KC} -n "${IDP_NAMESPACE}" rollout status deployment/dex --timeout=120s
else
  # Keycloak path — verify 03b-keycloak.sh has run.
  if ! ${KC} -n "${AGW_NAMESPACE}" get agentgatewaybackend keycloak-backend >/dev/null 2>&1; then
    echo "ERROR: keycloak-backend not found. Run scripts/03b-keycloak.sh first, or set IDP=dex."
    exit 1
  fi
  log "Keycloak backend + routes already in place (from 03b-keycloak.sh)"
fi

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
# We cannot target the whole Gateway because /dex/* must remain
# unauthenticated — otherwise the OAuth login redirect would itself require
# a valid session. Instead we enumerate the protected routes by name.
# Routes created in later scripts (06, 08, 09) attach to this policy
# automatically once they exist.
###############################################################################
log "Attaching AuthConfig to MCP/UI HTTPRoutes (dex-route excluded)"
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

if [[ "${IDP}" == "keycloak" ]]; then
  TOKEN_PATH="/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
  AUTH_PATH="/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth"
  USERNAME_DEMO="demo"
else
  TOKEN_PATH="/dex/token"
  AUTH_PATH="/dex/auth"
  USERNAME_DEMO="demo@example.com"
fi

echo ""
echo "=== DEMO FLOWS (IDP=${IDP}) ==="
echo ""
echo "Issuer / OIDC discovery (reachable from a laptop, no port-forward):"
echo "  ${OIDC_BASE}/.well-known/openid-configuration"
echo ""
echo "--- Flow 1: Browser Login (auth code flow) ---"
echo "  Open in browser: http://${AGW_LB}/mcp"
echo "  → Redirected to login at http://${AGW_LB}${AUTH_PATH}?..."
echo "  → Login with: ${USERNAME_DEMO} / demo-pass"
echo "  → Redirected back to /callback → session established"
echo "  → MCP tools accessible"
echo ""
echo "--- Flow 2: MCP Client Token (password grant / Bearer) ---"
echo "  TOKEN=\$(curl -s -X POST 'http://${AGW_LB}${TOKEN_PATH}' \\"
echo "    -d 'grant_type=password' \\"
echo "    -d 'username=${USERNAME_DEMO}' -d 'password=demo-pass' \\"
echo "    -d 'client_id=${OIDC_CLIENT_ID}' -d 'client_secret=${OIDC_CLIENT_SECRET}' \\"
echo "    -d 'scope=openid email profile' | jq -r '.access_token')"
echo ""
echo "  curl -s -H \"Authorization: Bearer \${TOKEN}\" http://${AGW_LB}/mcp"
echo ""
if [[ "${IDP}" == "keycloak" ]]; then
  echo "--- Flow 3 (Keycloak only): client-credentials m2m grant ---"
  echo "  TOKEN=\$(curl -s -X POST 'http://${AGW_LB}${TOKEN_PATH}' \\"
  echo "    -d 'grant_type=client_credentials' \\"
  echo "    -d 'client_id=mcp-service' -d 'client_secret=mcp-service-secret' \\"
  echo "    | jq -r '.access_token')"
  echo ""
fi
echo "Resources:"
${KC} get secret oauth-dex -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get agentgatewaybackend "${IDP_BACKEND_NAME}" -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get authconfig oidc-dex -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get enterpriseagentgatewaypolicy oidc-extauth -n "${AGW_NAMESPACE}" -o name 2>/dev/null
