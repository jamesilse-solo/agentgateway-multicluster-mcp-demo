#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-areg-enterprise.sh — Deploy AgentRegistry Enterprise (latest)
#
# Installs AgentRegistry Enterprise on cluster1.
# Wires it to AgentGateway as an MCP backend at /mcp/registry.
#
# Run AFTER 03-dex.sh (Dex must be running for OIDC config).
# Run BEFORE or AFTER 05-extauth.sh (order doesn't matter).
# Run BEFORE 07-register-mcp-servers.sh.
#
# Usage:
#   ./04-areg-enterprise.sh
#   AREG_VERSION=0.0.13 ./04-areg-enterprise.sh   # pin a specific version
###############################################################################

# ─── Optional Parameters ─────────────────────────────────────────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"

AREG_HELM_REPO="${AREG_HELM_REPO:-oci://us-docker.pkg.dev/agentregistry/enterprise/helm/agentregistry-enterprise}"

# Auto-detect latest version from OCI unless explicitly pinned.
if [[ -z "${AREG_VERSION:-}" ]]; then
  _latest=$(helm show chart "${AREG_HELM_REPO}" 2>/dev/null | awk '/^version:/{print $2}')
  AREG_VERSION="${_latest:?Cannot auto-detect AREG_VERSION from OCI — set it explicitly: export AREG_VERSION=0.0.13}"
fi

DEX_ISSUER="http://dex.${DEX_NAMESPACE}.svc.cluster.local:5556/dex"
DEX_CLIENT_ID="${DEX_CLIENT_ID:-agw-client}"
DEX_CLIENT_SECRET="${DEX_CLIENT_SECRET:-agw-client-secret}"

KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

###############################################################################
# 1. Create namespace + ambient label
###############################################################################
log "Creating agentregistry namespace"
${KC} create namespace "${AREG_NAMESPACE}" --dry-run=client -o yaml | ${KC} apply -f -
${KC} label namespace "${AREG_NAMESPACE}" istio.io/dataplane-mode=ambient --overwrite

###############################################################################
# 2. Install AgentRegistry Enterprise
#
# Key config choices for demo:
#   - OIDC via Dex: AREG uses the same Dex IDP as AgentGateway.
#     Requires the areg-public public client to exist in Dex (03-dex.sh adds it).
#   - disableBuiltinSeed=false: seeds 363 community MCP server entries on startup
#   - bundled postgres + ClickHouse: all-in-one, no external dependencies
#
# NOTE: The enterprise image has a .env baked in with a default OIDC_ISSUER that
# points to an internal Keycloak instance. Populating oidc.issuer in these values
# causes the chart to emit OIDC_ISSUER as an env var, which overrides the .env.
###############################################################################
log "Installing AgentRegistry Enterprise ${AREG_VERSION}"

# Allow stable JWT key across re-runs; generate once if not provided
JWT_KEY="${AREG_JWT_KEY:-$(openssl rand -hex 32)}"

helm upgrade --install agentregistry "${AREG_HELM_REPO}" \
  --namespace "${AREG_NAMESPACE}" \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${AREG_VERSION}" \
  --wait \
  --timeout 10m \
  -f - <<EOF
config:
  enableAnonymousAuth: "false"
  disableBuiltinSeed: "true"
  jwtPrivateKey: "${JWT_KEY}"

oidc:
  issuer: "${DEX_ISSUER}"
  clientId: "${DEX_CLIENT_ID}"
  publicClientId: "areg-public"
  clientSecret: "${DEX_CLIENT_SECRET}"
  # Dex JWTs have no "groups" claim — map admin role by email instead.
  # CEL expression: "email" in claims ? grants admin to the demo user : []
  roleMapper: '"email" in claims && claims["email"] == "demo@example.com" ? ["admin"] : []'
  # v0.0.14 changed the default superuserRole from "admin" to "". Set it
  # explicitly so the CEL-granted "admin" role is recognised as a superuser.
  superuserRole: "admin"

database:
  postgres:
    vectorEnabled: false
    bundled:
      enabled: true

clickhouse:
  enabled: true
  persistentVolume:
    enabled: false

telemetry:
  enabled: true
EOF

###############################################################################
# 3. Wire AgentRegistry MCP endpoint to AgentGateway
#
# AgentRegistry exposes its MCP catalog on port 31313.
# We create an AgentgatewayBackend + HTTPRoute so AI clients can discover
# registry-managed MCP servers through the same authenticated hub gateway.
###############################################################################
log "Wiring AgentRegistry MCP endpoint to AgentGateway (port 31313)"

# The Helm chart names the service agentregistry-agentregistry-enterprise
AREG_SVC="agentregistry-agentregistry-enterprise.${AREG_NAMESPACE}.svc.cluster.local"

${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agent-registry-backend
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: agent-registry-mcp
      static:
        host: ${AREG_SVC}
        port: 31313
EOF

${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: areg-mcp-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/registry
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: agent-registry-backend
      namespace: ${AGW_NAMESPACE}
EOF

###############################################################################
# 4. Summary
###############################################################################
log "AgentRegistry Enterprise ${AREG_VERSION} deployed"

echo ""
AREG_SVC_NAME="agentregistry-agentregistry-enterprise"
echo "Access:"
echo "  Catalog UI (port-forward):  ${KC} -n ${AREG_NAMESPACE} port-forward svc/${AREG_SVC_NAME} 8080:8080"
echo "                               http://localhost:8080"
echo "  MCP via AGW:                http://<agw-lb>/mcp/registry  (auth required)"
echo "  MCP direct (port-forward):  ${KC} -n ${AREG_NAMESPACE} port-forward svc/${AREG_SVC_NAME} 31313:31313"
echo "                               http://localhost:31313/mcp"
echo ""
echo "AgentgatewayBackend:"
${KC} get agentgatewaybackend agent-registry-backend -n "${AGW_NAMESPACE}" --no-headers 2>/dev/null || true
echo ""
echo "Helm releases:"
helm list -n "${AREG_NAMESPACE}" --kube-context "${KUBE_CONTEXT}"
echo ""
echo "Pods:"
${KC} get pods -n "${AREG_NAMESPACE}"
echo ""
echo "Next: Run 05-extauth.sh to enable Dex OIDC on AgentGateway"
