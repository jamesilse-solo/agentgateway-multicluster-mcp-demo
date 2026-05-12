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
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
DEX_CLIENT_ID="${DEX_CLIENT_ID:-agw-client}"
DEX_CLIENT_SECRET="${DEX_CLIENT_SECRET:-agw-client-secret}"
AGW_HELM_REPO="${AGW_HELM_REPO:-us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
AGW_VERSION="${AGW_VERSION:-v2.3.0-rc.3}"

# Get AGW LB address (required — must exist before this script runs)
AGW_LB=$(kubectl --context "${KUBE_CONTEXT}" -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [[ -z "${AGW_LB}" ]]; then
  echo "ERROR: agentgateway-hub LoadBalancer address not yet provisioned. Wait for 04a to complete and retry."
  exit 1
fi

# Dex must be reachable from external MCP clients (laptops, IDEs) for the
# OAuth authorization-code flow to complete. We expose /dex/* through the
# AGW Hub LB and pin both the Dex `issuer` and the ExtAuth `issuerUrl` to
# the same external URL so JWT `iss` claims match.
DEX_ISSUER_EXTERNAL="http://${AGW_LB}/dex"
DEX_ISSUER_URL="${DEX_ISSUER_EXTERNAL}/"
DEMO_APP_URL="${DEMO_APP_URL:-http://${AGW_LB}}"

# ─── Helper ───────────────────────────────────────────────────────────────────
KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

log "AgentGateway LB: ${AGW_LB}"
log "Dex issuer:      ${DEX_ISSUER_URL}"
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
# 2. Store Dex client secret
###############################################################################
log "Storing Dex client secret"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: oauth-dex
  namespace: ${AGW_NAMESPACE}
type: extauth.solo.io/oauth
stringData:
  client-secret: ${DEX_CLIENT_SECRET}
EOF

###############################################################################
# 3. Create AgentgatewayBackend + HTTPRoute that expose Dex via the AGW LB
#
# Dex was deployed in 03-dex.sh with an in-cluster ClusterIP. For external
# MCP clients to complete the OAuth authorization-code flow (auth → consent
# → callback → token exchange), every URL Dex emits must be reachable from
# outside the cluster. We achieve this by routing /dex/* through the AGW
# Hub LoadBalancer to the Dex Service.
###############################################################################
log "Creating AgentgatewayBackend for Dex"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: dex-backend
  namespace: ${AGW_NAMESPACE}
spec:
  static:
    host: dex.${DEX_NAMESPACE}.svc.cluster.local
    port: 5556
EOF

log "Creating HTTPRoute /dex/* → dex-backend (no ExtAuth — Dex auth flow itself)"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: dex-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /dex
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: dex-backend
      namespace: ${AGW_NAMESPACE}
EOF

###############################################################################
# 3a. Patch Dex configmap so its `issuer` matches the external URL
#
# Dex was originally deployed with the in-cluster FQDN. JWTs Dex issues
# embed the `iss` claim verbatim — for ExtAuth's OIDC validation to succeed,
# the token's iss MUST equal the AuthConfig's issuerUrl. We patch the
# configmap and roll Dex once.
###############################################################################
log "Patching Dex configmap to use external issuer: ${DEX_ISSUER_EXTERNAL}"
CURRENT_CONFIG=$(${KC} -n "${DEX_NAMESPACE}" get configmap dex-config \
  -o jsonpath='{.data.config\.yaml}')
NEW_CONFIG=$(echo "${CURRENT_CONFIG}" \
  | sed -E "s|^issuer:.*|issuer: ${DEX_ISSUER_EXTERNAL}|")
${KC} -n "${DEX_NAMESPACE}" create configmap dex-config \
  --from-literal=config.yaml="${NEW_CONFIG}" \
  --dry-run=client -o yaml | ${KC} apply -f -
${KC} -n "${DEX_NAMESPACE}" rollout restart deployment/dex
${KC} -n "${DEX_NAMESPACE}" rollout status deployment/dex --timeout=120s

###############################################################################
# 4. Create AuthConfig (OIDC authorization code flow via Dex)
###############################################################################
log "Creating AuthConfig for Dex OIDC"
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
        clientId: ${DEX_CLIENT_ID}
        clientSecretRef:
          name: oauth-dex
          namespace: ${AGW_NAMESPACE}
        issuerUrl: "${DEX_ISSUER_URL}"
        scopes:
        - openid
        - email
        - profile
        session:
          failOnFetchFailure: true
          redis:
            cookieName: dex-session
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

echo ""
echo "=== DEMO FLOWS ==="
echo ""
echo "Dex is reachable from your laptop directly through the AGW LB at:"
echo "  http://${AGW_LB}/dex/.well-known/openid-configuration"
echo "  (no port-forward needed — /dex/* is routed via dex-route HTTPRoute)"
echo ""
echo "--- Flow 1: Browser Login (auth code flow) ---"
echo "  Open in browser: http://${AGW_LB}/mcp"
echo "  → Redirected to Dex login at http://${AGW_LB}/dex/auth?..."
echo "  → Login with: demo@example.com / demo-pass"
echo "  → Redirected back to /callback → session established"
echo "  → MCP tools accessible"
echo ""
echo "--- Flow 2: MCP Client Token (password grant / Bearer) ---"
echo "  # 1. Get token from Dex through the AGW LB (no port-forward needed)"
echo "  TOKEN=\$(curl -s -X POST 'http://${AGW_LB}/dex/token' \\"
echo "    -H 'Content-Type: application/x-www-form-urlencoded' \\"
echo "    -d 'grant_type=password&username=demo@example.com&password=demo-pass' \\"
echo "    -d 'client_id=${DEX_CLIENT_ID}&client_secret=${DEX_CLIENT_SECRET}&scope=openid+email+profile' \\"
echo "    | jq -r '.id_token')"
echo ""
echo "  # 2. Unauthenticated → 302 redirect to Dex:"
echo "  curl -s -o /dev/null -w '%{http_code}\n' http://${AGW_LB}/mcp"
echo ""
echo "  # 3. Authenticated → 200 OK with MCP tools:"
echo "  curl -s -H \"Authorization: Bearer \${TOKEN}\" http://${AGW_LB}/mcp"
echo ""
echo "Resources:"
${KC} get secret oauth-dex -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get agentgatewaybackend dex-backend -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get authconfig oidc-dex -n "${AGW_NAMESPACE}" -o name 2>/dev/null
${KC} get enterpriseagentgatewaypolicy oidc-extauth -n "${AGW_NAMESPACE}" -o name 2>/dev/null
