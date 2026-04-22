#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 02-configure.sh — Cross-Cluster Peering & AgentGateway Configuration
#
# Run this script on each cluster AFTER 01-install.sh has been validated on
# both clusters. This script runs against a single cluster context and
# configures it to peer with the remote cluster.
#
# Usage (Hub — Cluster 1):
#   export CLUSTER_NAME=cluster1
#   export NETWORK_NAME=cluster1
#   export REMOTE_CLUSTER_NAME=cluster2
#   export REMOTE_NETWORK_NAME=cluster2
#   export REMOTE_EW_ADDRESS=<cluster2-ew-hostname-or-ip>
#   export GATEWAY_ROLE=hub
#   export GLOO_MESH_LICENSE_KEY=<key>
#   ./02-configure.sh
#
# Usage (Spoke — Cluster 2):
#   export CLUSTER_NAME=cluster2
#   export NETWORK_NAME=cluster2
#   export REMOTE_CLUSTER_NAME=cluster1
#   export REMOTE_NETWORK_NAME=cluster1
#   export REMOTE_EW_ADDRESS=<cluster1-ew-hostname-or-ip>
#   export GATEWAY_ROLE=spoke
#   ./02-configure.sh
###############################################################################

# ─── Required Parameters ─────────────────────────────────────────────────────
: "${CLUSTER_NAME:?CLUSTER_NAME is required (e.g. cluster1)}"
: "${NETWORK_NAME:?NETWORK_NAME is required (e.g. cluster1)}"
: "${REMOTE_CLUSTER_NAME:?REMOTE_CLUSTER_NAME is required (e.g. cluster2)}"
: "${REMOTE_NETWORK_NAME:?REMOTE_NETWORK_NAME is required (e.g. cluster2)}"
: "${REMOTE_EW_ADDRESS:?REMOTE_EW_ADDRESS is required — east-west gateway hostname or IP of the remote cluster}"
: "${GATEWAY_ROLE:?GATEWAY_ROLE is required — 'hub' or 'spoke'}"

# ─── Optional Parameters ─────────────────────────────────────────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-${CLUSTER_NAME}}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.1}"
ISTIO_IMAGE="${ISTIO_IMAGE:-${ISTIO_VERSION}-solo}"
ISTIO_HELM_REPO="${ISTIO_HELM_REPO:-us-docker.pkg.dev/soloio-img/istio-helm}"
REMOTE_EW_ADDRESS_TYPE="${REMOTE_EW_ADDRESS_TYPE:-Hostname}"
REGION="${REGION:-us-west-2}"

# ─── Helper ───────────────────────────────────────────────────────────────────
KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

# Validate GATEWAY_ROLE
if [[ "${GATEWAY_ROLE}" != "hub" && "${GATEWAY_ROLE}" != "spoke" ]]; then
  echo "ERROR: GATEWAY_ROLE must be 'hub' or 'spoke', got '${GATEWAY_ROLE}'"
  exit 1
fi

GATEWAY_NAME="agentgateway-${GATEWAY_ROLE}"

###############################################################################
# 1. Peer with Remote Cluster
###############################################################################
log "Peering ${CLUSTER_NAME} with remote cluster ${REMOTE_CLUSTER_NAME} at ${REMOTE_EW_ADDRESS}"
helm upgrade -i peering-remote "oci://${ISTIO_HELM_REPO}/peering" \
  --version "${ISTIO_IMAGE}" \
  --namespace istio-eastwest \
  --kube-context "${KUBE_CONTEXT}" \
  -f - <<EOF
remote:
  create: true
  items:
    - name: istio-remote-peer-${REMOTE_CLUSTER_NAME}
      cluster: ${REMOTE_CLUSTER_NAME}
      network: ${REMOTE_NETWORK_NAME}
      addressType: ${REMOTE_EW_ADDRESS_TYPE}
      address: ${REMOTE_EW_ADDRESS}
      preferredDataplaneServiceType: loadbalancer
      trustDomain: cluster.local
      region: ${REGION}
EOF

###############################################################################
# 2. Configure AgentGateway Proxy
###############################################################################
log "Configuring AgentGateway proxy as ${GATEWAY_ROLE} (${GATEWAY_NAME})"
${KC} apply -n agentgateway-system -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: agentgateway-system
  rules:
  - backendRefs:
    - name: mcp-server-everything
      port: 80
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-backends
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: mcp-server-everything-local
      selector:
        services:
          matchLabels:
            app: mcp-server-everything
EOF

###############################################################################
# 3. Summary & Validation Commands
###############################################################################
log "Configuration complete for ${CLUSTER_NAME} (${GATEWAY_ROLE})"

echo ""
echo "Peering:"
echo "  ${CLUSTER_NAME} -> ${REMOTE_CLUSTER_NAME} via ${REMOTE_EW_ADDRESS}"
echo ""
echo "AgentGateway proxy: ${GATEWAY_NAME}"
echo ""

echo "--- Validation Commands ---"
echo ""
echo "# Check peering status (run from a host with access to both contexts):"
echo "  istioctl multicluster check --verbose --contexts=\"${CLUSTER_NAME},${REMOTE_CLUSTER_NAME}\""
echo ""
echo "# Check east-west gateway status:"
echo "  ${KC} get gateways.gateway.networking.k8s.io -n istio-eastwest"
echo ""
echo "# Check agentgateway proxy:"
echo "  ${KC} get gateway -n agentgateway-system"
echo "  ${KC} get pods -n agentgateway-system"
echo ""
echo "# Check all pods:"
echo "  ${KC} get pods -A"
echo ""

if [[ "${GATEWAY_ROLE}" == "hub" ]]; then
  echo "# Port-forward to AgentGateway Hub:"
  echo "  ${KC} -n agentgateway-system port-forward svc/${GATEWAY_NAME} 8080:80"
  echo "  # Then connect MCP Inspector to: http://localhost:8080/mcp"
  echo ""
  echo "# Port-forward to Agent Registry UI:"
  echo "  ${KC} -n agentregistry port-forward svc/agentregistry 12121:12121"
  echo "  # Then open: http://localhost:12121"
fi
