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

# Dex internal service URL
DEX_ISSUER_URL="http://dex.${DEX_NAMESPACE}.svc.cluster.local:5556/dex/"

# Get AGW LB address
AGW_LB=$(kubectl --context "${KUBE_CONTEXT}" -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
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
# 3. Create AgentgatewayBackend for Dex
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
# 5. Attach AuthConfig to agentgateway-hub Gateway
###############################################################################
log "Attaching AuthConfig to agentgateway-hub via EnterpriseAgentgatewayPolicy"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: oidc-extauth
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-hub
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
echo "Port-forward Dex locally:"
echo "  ${KC} -n ${DEX_NAMESPACE} port-forward svc/dex 5556:5556 &"
echo ""
echo "--- Flow 1: Browser Login (auth code flow) ---"
echo "  Open in browser: http://${AGW_LB}/mcp"
echo "  → Redirected to Dex login at http://localhost:5556/dex/auth?..."
echo "  → Login with: demo@example.com / demo-pass"
echo "  → Redirected back to /callback → session established"
echo "  → MCP tools accessible"
echo ""
echo "--- Flow 2: MCP Client Token (password grant / Bearer) ---"
echo "  # 1. Get token from Dex (must port-forward Dex or use in-cluster curl)"
echo "  TOKEN=\$(curl -s -X POST 'http://localhost:5556/dex/token' \\"
echo "    -H 'Content-Type: application/x-www-form-urlencoded' \\"
echo "    -d 'grant_type=password&username=demo@example.com&password=demo-pass' \\"
echo "    -d 'client_id=${DEX_CLIENT_ID}&client_secret=${DEX_CLIENT_SECRET}&scope=openid+email+profile' \\"
echo "    | jq -r '.access_token')"
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
