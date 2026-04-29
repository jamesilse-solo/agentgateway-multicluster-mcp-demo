#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-areg.sh — Deploy AgentRegistry OSS (latest)
#
# Installs AgentRegistry OSS on cluster1.
# Wires it to AgentGateway as an MCP backend at /mcp/registry.
#
# No OIDC in the OSS chart — anonymous access is enabled for demo use.
# Run BEFORE 07-register-mcp-servers.sh.
#
# Usage:
#   ./scripts/04-areg.sh
#   AREG_VERSION=0.3.3 ./scripts/04-areg.sh   # pin a specific version
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"

AREG_HELM_REPO="${AREG_HELM_REPO:-oci://ghcr.io/agentregistry-dev/agentregistry/charts/agentregistry}"

# Auto-detect latest version from OCI unless explicitly pinned.
if [[ -z "${AREG_VERSION:-}" ]]; then
  _latest=$(helm show chart "${AREG_HELM_REPO}" 2>/dev/null | awk '/^version:/{print $2}')
  AREG_VERSION="${_latest:?Cannot auto-detect AREG_VERSION from OCI — set it explicitly: export AREG_VERSION=0.3.3}"
fi

KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

###############################################################################
# 1. Create namespace + ambient label
###############################################################################
log "Creating agentregistry namespace"
${KC} create namespace "${AREG_NAMESPACE}" --dry-run=client -o yaml | ${KC} apply -f -
${KC} label namespace "${AREG_NAMESPACE}" istio.io/dataplane-mode=ambient --overwrite

###############################################################################
# 2. Install AgentRegistry OSS
###############################################################################
log "Installing AgentRegistry OSS ${AREG_VERSION}"

JWT_KEY="${AREG_JWT_KEY:-$(openssl rand -hex 32)}"

helm upgrade --install agentregistry "${AREG_HELM_REPO}" \
  --namespace "${AREG_NAMESPACE}" \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${AREG_VERSION}" \
  --wait \
  --timeout 10m \
  --set image.registry=docker.io \
  --set image.repository=pmuir \
  --set image.name=agentregistry-server \
  --set image.tag=add-agentgateway-resource \
  -f - <<EOF
config:
  # No OIDC in OSS — anonymous access for demo use.
  enableAnonymousAuth: "true"
  disableBuiltinSeed: "true"
  jwtPrivateKey: "${JWT_KEY}"

database:
  postgres:
    vectorEnabled: false
    bundled:
      enabled: true
      image:
        registry: docker.io
        repository: pgvector
        name: pgvector
        tag: "pg18"
EOF

###############################################################################
# 3. Wire AgentRegistry MCP endpoint to AgentGateway
###############################################################################
log "Wiring AgentRegistry MCP endpoint to AgentGateway (port 31313)"

AREG_SVC="agentregistry.${AREG_NAMESPACE}.svc.cluster.local"

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
log "AgentRegistry OSS ${AREG_VERSION} deployed"

AREG_SVC_NAME="agentregistry"
echo ""
echo "Access:"
echo "  UI (port-forward):  ${KC} -n ${AREG_NAMESPACE} port-forward svc/${AREG_SVC_NAME} 8080:12121"
echo "                       http://localhost:8080  (no login required)"
echo "  MCP via AGW:        http://<agw-lb>/mcp/registry"
echo "  MCP direct:         ${KC} -n ${AREG_NAMESPACE} port-forward svc/${AREG_SVC_NAME} 31313:31313"
echo "                       http://localhost:31313/mcp"
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
echo "Next: Run 07-register-mcp-servers.sh to populate the catalog"
