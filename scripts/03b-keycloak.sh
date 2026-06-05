#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 03b-keycloak.sh — Deploy Keycloak as the IdP (replaces Dex going forward)
#
# Keycloak supports the things Dex v2.42 does not:
#   - client_credentials grant (OAuth 2.1 m2m flow)
#   - Refresh-token rotation
#   - Dynamic Client Registration (RFC 7591)
#   - Per-client audience scopes, fine-grained admin RBAC, realm imports
#
# What this script creates:
#   - Namespace `keycloak` (ambient-mesh labelled)
#   - ConfigMap with a realm import (solo-demo realm + 4 clients + 3 users)
#   - Deployment running Keycloak 26 in start-dev mode
#   - Service on port 8080
#   - AgentgatewayBackend `keycloak-backend` (cluster-internal address)
#   - HTTPRoutes exposing /realms/* and /resources/* through the AGW LB
#
# After this runs, the auth flow can be cut over from Dex to Keycloak by
# running 05-extauth.sh with IDP=keycloak (see that script for details).
#
# Prerequisites:
#   - 02-configure.sh has run (Gateway agentgateway-hub exists with LB)
#
# Usage:
#   ./scripts/03b-keycloak.sh
#   ./scripts/03b-keycloak.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.0.7}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing Keycloak"
  ${KC} -n "${AGW_NAMESPACE}" delete httproute keycloak-route --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete httproute keycloak-resources-route --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaybackend keycloak-backend --ignore-not-found

  # Remove keycloak routes from oidc-extauth policy targets (idempotent)
  ${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy oidc-extauth -o json 2>/dev/null \
    | jq '.spec.targetRefs |= map(select(.name | startswith("keycloak-") | not))' \
    | ${KC} apply -f - 2>/dev/null || true

  ${KC} delete namespace "${KEYCLOAK_NAMESPACE}" --ignore-not-found --wait=false
  echo "✓ Keycloak removed"
  exit 0
fi

###############################################################################
# 1. Resolve AGW LB (needed for realm issuer)
###############################################################################
AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
if [[ -z "${AGW_LB}" ]]; then
  echo "ERROR: AGW Hub LB not provisioned. Run 02-configure.sh + 04a-agw-management-ui.sh first."
  exit 1
fi
EXTERNAL_BASE="http://${AGW_LB}"
log "Keycloak will be reachable at: ${EXTERNAL_BASE}/realms/${KEYCLOAK_REALM}"

###############################################################################
# 2. Namespace + ambient mesh label
###############################################################################
log "Creating namespace ${KEYCLOAK_NAMESPACE}"
${KC} create namespace "${KEYCLOAK_NAMESPACE}" --dry-run=client -o yaml | ${KC} apply -f -
${KC} label namespace "${KEYCLOAK_NAMESPACE}" istio.io/dataplane-mode=ambient --overwrite

###############################################################################
# 3. Realm import ConfigMap
#
# realm.json defines the realm and all clients + users. The redirectUri
# entries embed the AGW LB so the OIDC callback works for laptop browsers.
###############################################################################
log "Applying realm import ConfigMap"
REALM_JSON=$(cat <<EOF
{
  "realm": "${KEYCLOAK_REALM}",
  "enabled": true,
  "sslRequired": "none",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": false,
  "editUsernameAllowed": false,
  "bruteForceProtected": false,
  "accessTokenLifespan": 3600,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000,
  "clients": [
    {
      "clientId": "agw-client",
      "name": "AgentGateway MCP Client",
      "secret": "agw-client-secret",
      "enabled": true,
      "publicClient": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": false,
      "implicitFlowEnabled": false,
      "redirectUris": [
        "${EXTERNAL_BASE}/callback",
        "http://localhost:8080/callback",
        "http://localhost:6274/oauth/callback"
      ],
      "webOrigins": ["*"],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "use.refresh.tokens": "true"
      }
    },
    {
      "clientId": "mcp-service",
      "name": "OAuth 2.1 MCP Service Client (client-credentials)",
      "secret": "mcp-service-secret",
      "enabled": true,
      "publicClient": false,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": true,
      "implicitFlowEnabled": false
    },
    {
      "clientId": "tenant-a-client",
      "name": "Tenant A client",
      "secret": "tenant-a-client-secret",
      "enabled": true,
      "publicClient": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "redirectUris": ["${EXTERNAL_BASE}/callback"],
      "webOrigins": ["*"]
    },
    {
      "clientId": "tenant-b-client",
      "name": "Tenant B client",
      "secret": "tenant-b-client-secret",
      "enabled": true,
      "publicClient": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "redirectUris": ["${EXTERNAL_BASE}/callback"],
      "webOrigins": ["*"]
    }
  ],
  "users": [
    {
      "username": "demo",
      "email": "demo@example.com",
      "emailVerified": true,
      "firstName": "Demo",
      "lastName": "User",
      "enabled": true,
      "credentials": [{"type": "password", "value": "demo-pass", "temporary": false}]
    },
    {
      "username": "tenant-a-agent",
      "email": "tenant-a-agent@example.com",
      "emailVerified": true,
      "firstName": "Tenant A",
      "lastName": "Agent",
      "enabled": true,
      "credentials": [{"type": "password", "value": "tenant-a-pass", "temporary": false}],
      "groups": ["tenant-a"]
    },
    {
      "username": "tenant-b-agent",
      "email": "tenant-b-agent@example.com",
      "emailVerified": true,
      "firstName": "Tenant B",
      "lastName": "Agent",
      "enabled": true,
      "credentials": [{"type": "password", "value": "tenant-b-pass", "temporary": false}],
      "groups": ["tenant-b"]
    }
  ],
  "groups": [
    {"name": "tenant-a"},
    {"name": "tenant-b"}
  ]
}
EOF
)

${KC} -n "${KEYCLOAK_NAMESPACE}" create configmap keycloak-realm \
  --from-literal=realm.json="${REALM_JSON}" \
  --dry-run=client -o yaml | ${KC} apply -f -

###############################################################################
# 4. Keycloak Deployment + Service
#
# start-dev mode is fine for a demo — boots in seconds, no database setup.
# --import-realm imports the configmap-mounted realm.json on first start.
# --hostname-strict=false lets Keycloak accept requests on any hostname
# (we'll come in via the AGW LB which is a different hostname than the
# service DNS name).
###############################################################################
log "Deploying Keycloak (${KEYCLOAK_IMAGE})"
${KC} apply -n "${KEYCLOAK_NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: ${KEYCLOAK_IMAGE}
        args: ["start-dev", "--import-realm"]
        env:
        - name: KC_BOOTSTRAP_ADMIN_USERNAME
          value: "${KEYCLOAK_ADMIN_USER}"
        - name: KC_BOOTSTRAP_ADMIN_PASSWORD
          value: "${KEYCLOAK_ADMIN_PASSWORD}"
        - name: KC_HEALTH_ENABLED
          value: "true"
        - name: KC_METRICS_ENABLED
          value: "true"
        - name: KC_HOSTNAME_STRICT
          value: "false"
        - name: KC_HOSTNAME
          value: "${AGW_LB}"
        - name: KC_PROXY_HEADERS
          value: "xforwarded"
        - name: KC_HTTP_ENABLED
          value: "true"
        - name: KC_HTTP_RELATIVE_PATH
          value: "/"
        ports:
        - name: http
          containerPort: 8080
        - name: mgmt
          containerPort: 9000
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 5
          failureThreshold: 60
        livenessProbe:
          httpGet:
            path: /health/live
            port: 9000
          initialDelaySeconds: 60
          periodSeconds: 10
        volumeMounts:
        - name: realm
          mountPath: /opt/keycloak/data/import
        resources:
          requests:
            cpu: 200m
            memory: 768Mi
          limits:
            memory: 1536Mi
      volumes:
      - name: realm
        configMap:
          name: keycloak-realm
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${KEYCLOAK_NAMESPACE}
  labels:
    app: keycloak
    # Expose the service cross-cluster through HBONE so spoke clusters
    # can reach the JWKS endpoint at keycloak.keycloak.mesh.internal:8080
    # — required when a spoke-cluster EAGP wires
    # traffic.jwtAuthentication.mcp.jwks.remote against this issuer.
    solo.io/service-scope: global
  annotations:
    networking.istio.io/traffic-distribution: Any
spec:
  selector:
    app: keycloak
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  - name: mgmt
    port: 9000
    targetPort: 9000
  type: ClusterIP
EOF

log "Waiting for Keycloak rollout (can take 60-90s on first boot)"
${KC} -n "${KEYCLOAK_NAMESPACE}" rollout status deploy/keycloak --timeout=300s

###############################################################################
# 5. AGW backend + routes (expose /realms/* and /resources/* through the LB)
###############################################################################
log "Wiring Keycloak through the AGW LB"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: keycloak-backend
  namespace: ${AGW_NAMESPACE}
spec:
  static:
    host: keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local
    port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /realms
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: keycloak-backend
      namespace: ${AGW_NAMESPACE}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak-resources-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /resources
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: keycloak-backend
      namespace: ${AGW_NAMESPACE}
EOF

###############################################################################
# 6. Sanity check — fetch the realm OIDC discovery doc through the LB
###############################################################################
log "Verifying realm discovery"
sleep 5
ISSUER_URL="${EXTERNAL_BASE}/realms/${KEYCLOAK_REALM}"
DISCOVERY=$(curl -s -o /tmp/kc-discovery.json -w "%{http_code}" \
  "${ISSUER_URL}/.well-known/openid-configuration")
if [[ "${DISCOVERY}" == "200" ]]; then
  echo "  ✓ ${ISSUER_URL}/.well-known/openid-configuration → 200"
  jq -r '"  issuer: \(.issuer)\n  token_endpoint: \(.token_endpoint)\n  authorization_endpoint: \(.authorization_endpoint)"' /tmp/kc-discovery.json
else
  echo "  ⚠ Discovery endpoint returned HTTP ${DISCOVERY} — Keycloak may still be warming up"
  echo "    Retry in 30s: curl -s ${ISSUER_URL}/.well-known/openid-configuration | jq .issuer"
fi
rm -f /tmp/kc-discovery.json

log "Keycloak deployment complete"
cat <<EOF

Realm issuer (external):   ${ISSUER_URL}
Admin console (cluster):   http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080/
Admin credentials:         ${KEYCLOAK_ADMIN_USER} / ${KEYCLOAK_ADMIN_PASSWORD}

Get a Bearer token (password grant):
  curl -s -X POST "${ISSUER_URL}/protocol/openid-connect/token" \\
    -d 'grant_type=password' \\
    -d 'username=demo' -d 'password=demo-pass' \\
    -d 'client_id=agw-client' -d 'client_secret=agw-client-secret' \\
    -d 'scope=openid email profile' | jq -r .access_token

Get a Bearer token (client-credentials — m2m):
  curl -s -X POST "${ISSUER_URL}/protocol/openid-connect/token" \\
    -d 'grant_type=client_credentials' \\
    -d 'client_id=mcp-service' -d 'client_secret=mcp-service-secret' | jq -r .access_token

Next: run scripts/05-extauth.sh with IDP=keycloak to cut ExtAuth over.

To remove: ./scripts/03b-keycloak.sh --cleanup
EOF
