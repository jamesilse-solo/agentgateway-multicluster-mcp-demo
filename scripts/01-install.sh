#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 01-install.sh — Per-Cluster Installation
#
# Run this script once per cluster from an isolated jumpbox.
# It installs all components on a single cluster. No cross-cluster operations.
# After running on both clusters, proceed to 02-configure.sh for peering.
#
# Usage:
#   export CLUSTER_NAME=cluster1
#   export NETWORK_NAME=cluster1
#   export GLOO_MESH_LICENSE_KEY=<key>
#   export AGENTGATEWAY_LICENSE_KEY=<key>
#   ./01-install.sh
###############################################################################

# ─── Required Parameters ─────────────────────────────────────────────────────
: "${CLUSTER_NAME:?CLUSTER_NAME is required (e.g. cluster1)}"
: "${NETWORK_NAME:?NETWORK_NAME is required (e.g. cluster1)}"
: "${GLOO_MESH_LICENSE_KEY:?GLOO_MESH_LICENSE_KEY is required}"
: "${AGENTGATEWAY_LICENSE_KEY:?AGENTGATEWAY_LICENSE_KEY is required}"
: "${CACERTS_DIR:?CACERTS_DIR is required — path to directory with ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem}"

# ─── Optional Parameters (override for artifact repo mirrors) ────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-${CLUSTER_NAME}}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.1}"
ISTIO_IMAGE="${ISTIO_IMAGE:-${ISTIO_VERSION}-solo}"
ISTIO_REPO="${ISTIO_REPO:-us-docker.pkg.dev/soloio-img/istio}"
ISTIO_HELM_REPO="${ISTIO_HELM_REPO:-us-docker.pkg.dev/soloio-img/istio-helm}"
AGW_HELM_REPO="${AGW_HELM_REPO:-us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
AGW_VERSION="${AGW_VERSION:-v2.3.3}"
GATEWAY_API_CRDS_FILE="${GATEWAY_API_CRDS_FILE:-}"
BOOKINFO_MANIFEST="${BOOKINFO_MANIFEST:-}"
NETSHOOT_IMAGE="${NETSHOOT_IMAGE:-nicolaka/netshoot:latest}"
NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"
REGION="${REGION:-us-west-2}"

# ─── Helper ───────────────────────────────────────────────────────────────────
KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

# ─── Validate inputs ─────────────────────────────────────────────────────────
for f in ca-cert.pem ca-key.pem root-cert.pem cert-chain.pem; do
  if [[ ! -f "${CACERTS_DIR}/${f}" ]]; then
    echo "ERROR: ${CACERTS_DIR}/${f} not found"; exit 1
  fi
done

###############################################################################
# 1. Create Namespaces
###############################################################################
log "Creating namespaces"
for NS in istio-system istio-eastwest bookinfo debug agentgateway-system; do
  ${KC} create namespace "${NS}" --dry-run=client -o yaml | ${KC} apply -f -
done

###############################################################################
# 2. Deploy CA Certificates
###############################################################################
log "Creating cacerts secret in istio-system"
${KC} create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem="${CACERTS_DIR}/ca-cert.pem" \
  --from-file=ca-key.pem="${CACERTS_DIR}/ca-key.pem" \
  --from-file=root-cert.pem="${CACERTS_DIR}/root-cert.pem" \
  --from-file=cert-chain.pem="${CACERTS_DIR}/cert-chain.pem" \
  --dry-run=client -o yaml | ${KC} apply -f -

###############################################################################
# 3. Install Gateway API CRDs
###############################################################################
log "Installing Gateway API CRDs"
if [[ -n "${GATEWAY_API_CRDS_FILE}" ]]; then
  ${KC} apply -f "${GATEWAY_API_CRDS_FILE}"
else
  ${KC} apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
fi

###############################################################################
# 4. Install Istio Base
###############################################################################
log "Installing istio-base"
helm upgrade --install istio-base "oci://${ISTIO_HELM_REPO}/base" \
  --namespace istio-system \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${ISTIO_IMAGE}" \
  -f - <<EOF
profile: ambient
defaultRevision: main
EOF

###############################################################################
# 5. Install istiod
###############################################################################
log "Installing istiod (cluster=${CLUSTER_NAME}, network=${NETWORK_NAME})"
helm upgrade --install istiod "oci://${ISTIO_HELM_REPO}/istiod" \
  --namespace istio-system \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${ISTIO_IMAGE}" \
  --wait \
  -f - <<EOF
global:
  hub: ${ISTIO_REPO}
  tag: ${ISTIO_IMAGE}
  variant: distroless
  proxy:
    clusterDomain: cluster.local
  multiCluster:
    clusterName: ${CLUSTER_NAME}
  network: ${NETWORK_NAME}
profile: ambient
revision: main
meshConfig:
  accessLogFile: /dev/stdout
  defaultConfig:
    proxyMetadata:
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
      ISTIO_META_DNS_CAPTURE: "true"
  trustDomain: cluster.local
pilot:
  cni:
    namespace: istio-system
    enabled: true
  enabled: true
  env:
    PILOT_ENABLE_IP_AUTOALLOCATE: "true"
    PILOT_ENABLE_K8S_SELECT_WORKLOAD_ENTRIES: "false"
    PILOT_SKIP_VALIDATE_TRUST_DOMAIN: "true"
    AUTO_RELOAD_PLUGIN_CERTS: "true"
    DISABLE_LEGACY_MULTICLUSTER: "true"
platforms:
  peering:
    enabled: true
revisionTags:
- default
license:
  value: ${GLOO_MESH_LICENSE_KEY}
EOF

###############################################################################
# 6. Install istio-cni
###############################################################################
log "Installing istio-cni"
helm upgrade --install istio-cni "oci://${ISTIO_HELM_REPO}/cni" \
  --namespace istio-system \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${ISTIO_IMAGE}" \
  -f - <<EOF
global:
  hub: ${ISTIO_REPO}
  tag: ${ISTIO_IMAGE}
  variant: distroless
profile: ambient
revision: main
cni:
  ambient:
    dnsCapture: true
  excludeNamespaces:
  - istio-system
  - kube-system
EOF

###############################################################################
# 7. Install ztunnel
###############################################################################
log "Installing ztunnel (cluster=${CLUSTER_NAME}, network=${NETWORK_NAME})"
helm upgrade --install ztunnel "oci://${ISTIO_HELM_REPO}/ztunnel" \
  --namespace istio-system \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${ISTIO_IMAGE}" \
  -f - <<EOF
configValidation: true
enabled: true
env:
  L7_ENABLED: "true"
  ISTIO_META_DNS_CAPTURE: "true"
  SKIP_VALIDATE_TRUST_DOMAIN: "true"
hub: ${ISTIO_REPO}
tag: ${ISTIO_IMAGE}
variant: distroless
istioNamespace: istio-system
namespace: istio-system
multiCluster:
  clusterName: ${CLUSTER_NAME}
network: ${NETWORK_NAME}
profile: ambient
proxy:
  clusterDomain: cluster.local
revision: main
EOF

###############################################################################
# 8. Label Namespaces
###############################################################################
log "Labeling namespaces"
${KC} label namespace istio-system topology.istio.io/network="${NETWORK_NAME}" --overwrite
${KC} label namespace bookinfo istio.io/dataplane-mode=ambient --overwrite
${KC} label namespace debug istio.io/dataplane-mode=ambient --overwrite
${KC} label namespace agentgateway-system istio.io/dataplane-mode=ambient --overwrite
###############################################################################
# 9. Deploy Bookinfo
###############################################################################
log "Deploying bookinfo"
if [[ -n "${BOOKINFO_MANIFEST}" ]]; then
  ${KC} apply -n bookinfo -f "${BOOKINFO_MANIFEST}"
else
  ${KC} apply -n bookinfo -f https://raw.githubusercontent.com/istio/istio/release-1.29/samples/bookinfo/platform/kube/bookinfo.yaml
fi

log "Labeling bookinfo services for cross-cluster discovery"
for SVC in productpage details ratings reviews; do
  ${KC} -n bookinfo label service "${SVC}" solo.io/service-scope=global --overwrite
  ${KC} -n bookinfo annotate service "${SVC}" networking.istio.io/traffic-distribution=Any --overwrite
done

###############################################################################
# 10. Deploy Netshoot Debug Pod
###############################################################################
log "Deploying netshoot debug pod"
${KC} apply -n debug -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netshoot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: netshoot
  template:
    metadata:
      labels:
        app: netshoot
    spec:
      containers:
      - name: netshoot
        image: ${NETSHOOT_IMAGE}
        command: ["sleep", "infinity"]
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
EOF

###############################################################################
# 11. Deploy East-West Gateway (local only — peering happens in 02-configure.sh)
###############################################################################
log "Deploying east-west gateway"
helm upgrade -i peering-eastwest "oci://${ISTIO_HELM_REPO}/peering" \
  --version "${ISTIO_IMAGE}" \
  --namespace istio-eastwest \
  --kube-context "${KUBE_CONTEXT}" \
  -f - <<EOF
eastwest:
  create: true
  cluster: ${CLUSTER_NAME}
  network: ${NETWORK_NAME}
  deployment: {}
EOF

###############################################################################
# 12. Install AgentGateway Enterprise
###############################################################################
log "Installing AgentGateway Enterprise CRDs (${AGW_VERSION})"
helm upgrade -i enterprise-agentgateway-crds \
  "oci://${AGW_HELM_REPO}/enterprise-agentgateway-crds" \
  --namespace agentgateway-system \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${AGW_VERSION}"

log "Installing AgentGateway Enterprise control plane (${AGW_VERSION})"
helm upgrade -i enterprise-agentgateway \
  "oci://${AGW_HELM_REPO}/enterprise-agentgateway" \
  -n agentgateway-system \
  --kube-context "${KUBE_CONTEXT}" \
  --version "${AGW_VERSION}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --set controller.image.pullPolicy=Always

###############################################################################
# 13. Deploy Dummy MCP Server
###############################################################################
log "Deploying mcp-server-everything"
${KC} apply -n agentgateway-system -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-server-everything
  namespace: agentgateway-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mcp-server-everything
  template:
    metadata:
      labels:
        app: mcp-server-everything
    spec:
      containers:
      - name: mcp-server
        image: ${NODE_IMAGE}
        command: ["npx", "-y", "mcp-proxy", "--port", "8080", "--", "npx", "-y", "@modelcontextprotocol/server-everything"]
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-server-everything
  namespace: agentgateway-system
  labels:
    app: mcp-server-everything
spec:
  selector:
    app: mcp-server-everything
  ports:
  - port: 80
    targetPort: 8080
    appProtocol: agentgateway.dev/mcp
EOF

###############################################################################
# Summary
###############################################################################
log "Installation complete for cluster: ${CLUSTER_NAME}"

echo ""
echo "Installed components:"
echo "  - Istio ambient ${ISTIO_VERSION} (base, istiod, cni, ztunnel)"
echo "  - East-west gateway (peering chart)"
echo "  - Bookinfo sample app"
echo "  - Netshoot debug pod"
echo "  - AgentGateway Enterprise ${AGW_VERSION}"
echo "  - MCP server (mcp-server-everything)"

echo ""
echo "Helm releases:"
helm list -A --kube-context "${KUBE_CONTEXT}"

echo ""
echo "East-West Gateway address (needed for 02-configure.sh):"
${KC} get svc -n istio-eastwest istio-eastwest -o jsonpath="{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}" 2>/dev/null || echo "(pending — check again in a few minutes)"
echo ""
echo ""
echo "Next: Run 02-configure.sh on both clusters to establish peering and configure AgentGateway proxies."
