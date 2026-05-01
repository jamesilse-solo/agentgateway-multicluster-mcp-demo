#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-areg.sh — Deploy AgentRegistry Enterprise
#
# Installs AgentRegistry Enterprise on cluster1.
# Uses Peter Muir's custom image with AgentGateway resource support.
# Wires it to AgentGateway as an MCP backend at /mcp/registry.
#
# The enterprise chart provides:
#   - Web UI with demo auth at http://localhost:8080 (via portforward)
#   - ClickHouse analytics + OTel collector
#   - Port 8080 (HTTP/UI), 21212 (AGW gRPC), 31313 (MCP)
#
# Run BEFORE 07-register-mcp-servers.sh.
#
# Usage:
#   ./scripts/04-areg.sh
#   AREG_VERSION=2026.04.1 ./scripts/04-areg.sh   # pin a specific version
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AREG_NAMESPACE="${AREG_NAMESPACE:-agentregistry}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"

AREG_HELM_REPO="${AREG_HELM_REPO:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise}"
AREG_VERSION="${AREG_VERSION:-2026.04.1}"
AREG_SVC_NAME="agentregistry-agentregistry-enterprise"

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
###############################################################################
log "Installing AgentRegistry Enterprise ${AREG_VERSION}"

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
  --set image.pullPolicy=Always \
  -f - <<EOF
config:
  disableBuiltinSeed: "true"
  jwtPrivateKey: "${JWT_KEY}"

oidc:
  demoAuthEnabled: true

database:
  postgres:
    vectorEnabled: false
    bundled:
      enabled: true
      image:
        registry: docker.io
        repository: library
        name: postgres
        tag: "18"

clickhouse:
  enabled: true
  auth:
    enabled: true
    username: "default"
    password: "password"
    skipUserSetup: false

telemetry:
  enabled: true
EOF

###############################################################################
# 3. Wire AgentRegistry MCP endpoint to AgentGateway
###############################################################################
log "Wiring AgentRegistry MCP endpoint to AgentGateway (port 31313)"

AREG_SVC="${AREG_SVC_NAME}.${AREG_NAMESPACE}.svc.cluster.local"

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
# 4. Pre-register MCP servers
###############################################################################
log "Pre-registering MCP servers in AgentRegistry"

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -z "${AGW_LB}" ]]; then
  echo "  ⚠  Could not resolve AGW LB — skipping server registration."
  echo "  Run ./scripts/07-register-mcp-servers.sh once the LB is ready."
else
  # Start temporary port-forward to AgentRegistry API
  pkill -f "port-forward.*${AREG_SVC_NAME}.*9999" 2>/dev/null || true
  ${KC} -n "${AREG_NAMESPACE}" port-forward "svc/${AREG_SVC_NAME}" 9999:8080 &>/dev/null &
  _PF=$!
  trap 'kill "${_PF}" 2>/dev/null || true' EXIT

  for i in $(seq 1 20); do
    curl -s --max-time 2 "http://localhost:9999/v0/servers" &>/dev/null && break
    [[ ${i} -eq 20 ]] && { echo "  ⚠  AgentRegistry not ready — skipping registration"; kill "${_PF}" 2>/dev/null; exit 0; }
    sleep 1
  done

  SCHEMA="https://static.modelcontextprotocol.io/schemas/2025-10-17/server.schema.json"

  _reg() {
    local name="$1" url="$2"
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      -X POST "http://localhost:9999/v0/servers" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${name}\",\"remotes\":[{\"url\":\"${url}\",\"schema\":\"${SCHEMA}\"}]}")
    if [[ "${http_code}" =~ ^2 ]]; then
      echo "  ✓ Registered: ${name}"
    else
      echo "  ⚠  ${name}: HTTP ${http_code} (may already exist)"
    fi
  }

  _reg "com.amazonaws/mcp-everything-local"  "http://${AGW_LB}/mcp"
  _reg "com.amazonaws/mcp-everything-remote" "http://${AGW_LB}/mcp/remote"
  _reg "io.solo/search-solo-io"              "https://search.solo.io/mcp"

  kill "${_PF}" 2>/dev/null || true
  trap - EXIT
fi

###############################################################################
# 5. Summary
###############################################################################
log "AgentRegistry Enterprise ${AREG_VERSION} deployed"

echo ""
echo "Access:"
echo "  UI (port-forward):  ${KC} -n ${AREG_NAMESPACE} port-forward svc/${AREG_SVC_NAME} 8080:8080"
echo "                       http://localhost:8080  (demo auth — log in with any credentials)"
echo "  API docs:            http://localhost:8080/docs"
echo "  MCP via AGW:         http://<agw-lb>/mcp/registry"
echo ""
echo "Pods:"
${KC} get pods -n "${AREG_NAMESPACE}"
