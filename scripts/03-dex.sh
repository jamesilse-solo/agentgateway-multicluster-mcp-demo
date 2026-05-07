#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 03-dex.sh — Deploy Dex OIDC Provider on Hub Cluster
#
# Deploys Dex v2.42.0 on cluster1 via plain manifests (ConfigMap + Deployment
# + Service). Configures:
#   - OIDC client: agw-client (for AgentGateway ExtAuth)
#   - Static user: demo@example.com / demo-pass
#   - Issuer: http://dex.dex.svc.cluster.local:5556/dex
#
# Dex handles both:
#   - Browser login flow (auth code → redirect → session)
#   - MCP client token flow (password grant → Bearer token → JWT validation)
#
# Run AFTER 02-configure.sh. Run BEFORE 05-extauth.sh.
#
# Usage:
#   ./03-dex.sh
###############################################################################

# ─── Optional Parameters ─────────────────────────────────────────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
DEX_CLIENT_ID="${DEX_CLIENT_ID:-agw-client}"
DEX_CLIENT_SECRET="${DEX_CLIENT_SECRET:-agw-client-secret}"
DEX_USER_EMAIL="${DEX_USER_EMAIL:-demo@example.com}"
DEX_USER_PASSWORD="${DEX_USER_PASSWORD:-demo-pass}"
DEX_USER_NAME="${DEX_USER_NAME:-demo-user}"
AGW_LB="${AGW_LB:-}"  # Optional: LB address for redirect URI

DEX_ISSUER="http://dex.${DEX_NAMESPACE}.svc.cluster.local:5556/dex"

KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

###############################################################################
# 1. Generate bcrypt hash for the demo user password
###############################################################################
log "Generating bcrypt password hash for ${DEX_USER_NAME}"
if command -v python3 &>/dev/null && python3 -c "import bcrypt" 2>/dev/null; then
  PASSWORD_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${DEX_USER_PASSWORD}', bcrypt.gensalt(rounds=10)).decode())")
elif command -v htpasswd &>/dev/null; then
  # -B = bcrypt, -C 10 = cost 10 (Dex requires cost >= 10; htpasswd -B alone defaults to cost 5)
  PASSWORD_HASH=$(htpasswd -iBC 10 -n x <<< "${DEX_USER_PASSWORD}" | cut -d: -f2)
else
  # Pre-computed bcrypt hash for "demo-pass" (cost 10)
  PASSWORD_HASH='$2b$10$SYAvnXXmpfp1.if/JXodKOPG7vCZW7CMvDSzK2LLkbw5G4S5/oIli'
  echo "  (using pre-computed hash — valid only if DEX_USER_PASSWORD=demo-pass)"
fi
echo "  Hash computed"

###############################################################################
# 2. Create namespace + ambient label
###############################################################################
log "Creating dex namespace"
${KC} create namespace "${DEX_NAMESPACE}" --dry-run=client -o yaml | ${KC} apply -f -
${KC} label namespace "${DEX_NAMESPACE}" istio.io/dataplane-mode=ambient --overwrite

###############################################################################
# 3. Deploy Dex via plain manifests
###############################################################################
log "Applying Dex ConfigMap"
${KC} apply -n "${DEX_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: dex-config
  namespace: ${DEX_NAMESPACE}
data:
  config.yaml: |
    issuer: ${DEX_ISSUER}

    storage:
      type: memory

    web:
      http: 0.0.0.0:5556
      # Allow the AgentRegistry UI (port-forwarded at localhost:8080) to make
      # cross-origin token requests to Dex (PKCE SPA callback flow).
      allowedOrigins:
      - "http://localhost:8080"

    oauth2:
      skipApprovalScreen: true
      responseTypes:
      - code
      passwordConnector: local

    staticClients:
    - id: ${DEX_CLIENT_ID}
      name: "AgentGateway MCP Client"
      secret: "${DEX_CLIENT_SECRET}"
      redirectURIs:
      - "http://localhost:8080/callback"
      - "http://${AGW_LB:-localhost}/callback"
      - "http://localhost:5556/callback"

    enablePasswordDB: true

    staticPasswords:
    - email: "${DEX_USER_EMAIL}"
      hash: '${PASSWORD_HASH}'
      username: "${DEX_USER_NAME}"
      userID: "demo-user-001"
EOF

log "Applying Dex Deployment"
${KC} apply -n "${DEX_NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dex
  namespace: ${DEX_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dex
  template:
    metadata:
      labels:
        app: dex
    spec:
      containers:
      - name: dex
        image: ghcr.io/dexidp/dex:v2.42.0
        command: ["/usr/local/bin/dex", "serve", "/etc/dex/config.yaml"]
        ports:
        - containerPort: 5556
        volumeMounts:
        - name: config
          mountPath: /etc/dex
        livenessProbe:
          httpGet:
            path: /dex/healthz
            port: 5556
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /dex/healthz
            port: 5556
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: config
        configMap:
          name: dex-config
EOF

log "Applying Dex Service"
${KC} apply -n "${DEX_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: dex
  namespace: ${DEX_NAMESPACE}
spec:
  selector:
    app: dex
  ports:
  - name: http
    port: 5556
    targetPort: 5556
  type: ClusterIP
EOF

###############################################################################
# 4. Wait for Dex to be ready
###############################################################################
log "Waiting for Dex rollout"
${KC} rollout status deploy/dex -n "${DEX_NAMESPACE}" --timeout=120s

###############################################################################
# 5. Verify Dex OIDC discovery endpoint
###############################################################################
log "Verifying Dex OIDC discovery endpoint"
sleep 3
DEX_POD=$(${KC} -n "${DEX_NAMESPACE}" get pod -l app=dex -o jsonpath='{.items[0].metadata.name}')
${KC} exec -n "${DEX_NAMESPACE}" "${DEX_POD}" -- \
  wget -qO- "http://localhost:5556/dex/.well-known/openid-configuration" 2>/dev/null \
  | python3 -m json.tool 2>/dev/null | grep -E '"issuer"|"token_endpoint"|"authorization_endpoint"' \
  || echo "  (discovery endpoint not yet ready)"

###############################################################################
# 6. Summary
###############################################################################
log "Dex deployment complete"

echo ""
echo "Dex issuer (internal):  ${DEX_ISSUER}"
echo "OIDC discovery:         ${DEX_ISSUER}/.well-known/openid-configuration"
echo "Client ID:              ${DEX_CLIENT_ID}"
echo "Client secret:          ${DEX_CLIENT_SECRET}"
echo "Demo user:              ${DEX_USER_EMAIL} / ${DEX_USER_PASSWORD}"
echo ""
echo "To port-forward Dex locally (for token acquisition):"
echo "  ${KC} -n ${DEX_NAMESPACE} port-forward svc/dex 5556:5556"
echo ""
echo "To get a token (password grant / MCP client flow):"
echo "  TOKEN=\$(curl -s -X POST http://localhost:5556/dex/token \\"
echo "    -d 'grant_type=password&username=${DEX_USER_EMAIL}&password=${DEX_USER_PASSWORD}' \\"
echo "    -d 'client_id=${DEX_CLIENT_ID}&client_secret=${DEX_CLIENT_SECRET}&scope=openid+email+profile' \\"
echo "    | jq -r '.access_token')"
echo ""
echo "Next: Run 05-extauth.sh to wire Dex into AgentGateway"
