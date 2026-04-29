#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 08-gloo-mesh-enterprise.sh — Install Gloo Mesh Enterprise on both clusters
#
# Installs Gloo Mesh Enterprise management plane on cluster1 (hub) and
# registers both clusters as managed workload clusters.
#
# Installation follows the air-gap pattern documented at:
#   https://docs.solo.io/gloo-mesh/latest/setup/setup/airgap/
# Image override flags are included as commented examples for air-gapped
# environments — remove the comments and set REGISTRY to enable.
#
# What this script does:
#   1. Adds the gloo-platform Helm repo
#   2. Installs Gloo Mesh management plane on cluster1 (gloo-mesh namespace)
#   3. Exposes the management server relay as a LoadBalancer on cluster1
#   4. Installs Gloo Mesh agent on cluster1 (connects locally)
#   5. Installs Gloo Mesh agent on cluster2 (connects via management LB)
#   6. Verifies both clusters appear in the management plane
#   7. Adds an HTTPRoute to AgentGateway for the Gloo Mesh UI (/gloo-mesh)
#   8. Prints full image list for air-gapped registry mirroring
#
# Prerequisites:
#   - 01-install.sh has run on both clusters (Istio ambient mesh up)
#   - 02-configure.sh has run (east-west peering established)
#   - GLOO_MESH_LICENSE_KEY is set
#
# Usage:
#   export GLOO_MESH_LICENSE_KEY=<key>
#   ./scripts/08-gloo-mesh-enterprise.sh
#
#   # Air-gapped (set registry, uncomment --set flags in script):
#   export REGISTRY=my-registry.internal
#   export GLOO_MESH_LICENSE_KEY=<key>
#   ./scripts/08-gloo-mesh-enterprise.sh
###############################################################################

: "${GLOO_MESH_LICENSE_KEY:?GLOO_MESH_LICENSE_KEY is required}"

# ─── Config ──────────────────────────────────────────────────────────────────
C1="${CLUSTER1_CONTEXT:-cluster1}"
C2="${CLUSTER2_CONTEXT:-cluster2}"
AGW_NS="${AGW_NS:-agentgateway-system}"
GM_NS="${GM_NS:-gloo-mesh}"
GLOO_VERSION="${GLOO_VERSION:-2.13.0}"
REGISTRY="${REGISTRY:-}"   # Set to override for air-gapped installs, e.g. my-registry.internal

KC1="kubectl --context ${C1}"
KC2="kubectl --context ${C2}"

log()  { echo ""; echo "=== $1 ==="; }
ok()   { echo "  ✓ $1"; }
info() { echo "  → $1"; }
fail() { echo "  ✗ $1"; exit 1; }

###############################################################################
# 0. Helm repo
###############################################################################
log "Adding gloo-platform Helm repo"
helm repo add gloo-platform https://storage.googleapis.com/gloo-platform/helm-charts 2>/dev/null || true
helm repo update gloo-platform
ok "Helm repo ready (version ${GLOO_VERSION})"

###############################################################################
# 1. Create gloo-mesh namespace on both clusters
###############################################################################
log "Creating gloo-mesh namespace"
${KC1} create namespace "${GM_NS}" --dry-run=client -o yaml | ${KC1} apply -f -
${KC1} label namespace "${GM_NS}" istio.io/dataplane-mode=ambient --overwrite
${KC2} create namespace "${GM_NS}" --dry-run=client -o yaml | ${KC2} apply -f -
${KC2} label namespace "${GM_NS}" istio.io/dataplane-mode=ambient --overwrite
ok "Namespaces ready on both clusters"

###############################################################################
# 2. Generate relay TLS certs (self-signed root shared across clusters)
###############################################################################
log "Generating relay mTLS certificates"
RELAY_TMP=$(mktemp -d)
trap 'rm -rf "${RELAY_TMP}"' EXIT

# Root CA for relay
openssl req -x509 -newkey rsa:4096 -keyout "${RELAY_TMP}/relay-root.key" \
  -out "${RELAY_TMP}/relay-root.crt" -days 3650 -nodes \
  -subj "/CN=gloo-mesh-relay-root" &>/dev/null

# Server cert for management server
openssl req -newkey rsa:4096 -keyout "${RELAY_TMP}/relay-server.key" \
  -out "${RELAY_TMP}/relay-server.csr" -nodes \
  -subj "/CN=gloo-mesh-mgmt-server" &>/dev/null
openssl x509 -req -in "${RELAY_TMP}/relay-server.csr" \
  -CA "${RELAY_TMP}/relay-root.crt" -CAkey "${RELAY_TMP}/relay-root.key" \
  -CAcreateserial -out "${RELAY_TMP}/relay-server.crt" -days 3650 &>/dev/null

# Client cert for agents
openssl req -newkey rsa:4096 -keyout "${RELAY_TMP}/relay-client.key" \
  -out "${RELAY_TMP}/relay-client.csr" -nodes \
  -subj "/CN=gloo-mesh-agent" &>/dev/null
openssl x509 -req -in "${RELAY_TMP}/relay-client.csr" \
  -CA "${RELAY_TMP}/relay-root.crt" -CAkey "${RELAY_TMP}/relay-root.key" \
  -CAcreateserial -out "${RELAY_TMP}/relay-client.crt" -days 3650 &>/dev/null

# Push secrets to both clusters
for KC_CMD in "${KC1}" "${KC2}"; do
  ${KC_CMD} -n "${GM_NS}" create secret generic relay-root-tls-secret \
    --from-file=ca.crt="${RELAY_TMP}/relay-root.crt" \
    --dry-run=client -o yaml | ${KC_CMD} apply -f -
  ${KC_CMD} -n "${GM_NS}" create secret generic relay-client-tls-secret \
    --from-file=tls.crt="${RELAY_TMP}/relay-client.crt" \
    --from-file=tls.key="${RELAY_TMP}/relay-client.key" \
    --from-file=ca.crt="${RELAY_TMP}/relay-root.crt" \
    --dry-run=client -o yaml | ${KC_CMD} apply -f -
done
${KC1} -n "${GM_NS}" create secret generic relay-server-tls-secret \
  --from-file=tls.crt="${RELAY_TMP}/relay-server.crt" \
  --from-file=tls.key="${RELAY_TMP}/relay-server.key" \
  --from-file=ca.crt="${RELAY_TMP}/relay-root.crt" \
  --dry-run=client -o yaml | ${KC1} apply -f -
ok "Relay TLS secrets created on both clusters"

###############################################################################
# 3. Install Gloo Mesh management plane on cluster1
###############################################################################
log "Installing Gloo Mesh Enterprise management plane on cluster1 (v${GLOO_VERSION})"

# Build image override flags (only added when REGISTRY is set)
MGMT_REGISTRY_FLAGS=""
if [[ -n "${REGISTRY}" ]]; then
  MGMT_REGISTRY_FLAGS="
    --set glooMgmtServer.image.registry=${REGISTRY}/gloo-mesh
    --set glooUi.image.registry=${REGISTRY}/gloo-mesh
    --set glooUi.sidecars.console.image.registry=${REGISTRY}/gloo-mesh
    --set glooUi.sidecars.envoy.image.registry=${REGISTRY}/gloo-mesh
    --set redis.deployment.image.registry=${REGISTRY}
    --set telemetryGateway.image.repository=${REGISTRY}/gloo-otel-collector
    --set prometheus.server.image.repository=${REGISTRY}/prometheus/prometheus
    --set prometheus.configmapReload.prometheus.image.repository=${REGISTRY}/prometheus-config-reloader"
fi

# shellcheck disable=SC2086
helm upgrade --install gloo-platform-mgmt gloo-platform/gloo-platform \
  --kube-context "${C1}" \
  --namespace "${GM_NS}" \
  --version "${GLOO_VERSION}" \
  --wait --timeout 10m \
  ${MGMT_REGISTRY_FLAGS} \
  -f - <<EOF
licensing:
  glooMeshLicenseKey: "${GLOO_MESH_LICENSE_KEY}"

common:
  cluster: cluster1

glooMgmtServer:
  enabled: true
  relay:
    serverAddress: "gloo-mesh-mgmt-server:9900"
    serverTlsSecretName: relay-server-tls-secret
    signingTlsSecretName: relay-server-tls-secret
    rootTlsSecretName: relay-root-tls-secret

glooAgent:
  enabled: false   # agent installed separately below

glooUi:
  enabled: true
  serviceType: ClusterIP

prometheus:
  enabled: true

telemetryGateway:
  enabled: true
  service:
    type: ClusterIP

telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: gloo-telemetry-gateway.gloo-mesh.svc:4317
EOF

ok "Management plane installed on cluster1"

###############################################################################
# 4. Expose management server relay as LoadBalancer (for cluster2 agent)
###############################################################################
log "Exposing management server relay as LoadBalancer"

${KC1} apply -n "${GM_NS}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: gloo-mesh-mgmt-server-relay-lb
  namespace: ${GM_NS}
spec:
  type: LoadBalancer
  selector:
    app: gloo-mesh-mgmt-server
  ports:
  - name: relay
    port: 9900
    targetPort: 9900
    protocol: TCP
EOF

info "Waiting for relay LoadBalancer address (up to 3 min)..."
RELAY_LB=""
for i in $(seq 1 36); do
  RELAY_LB=$(${KC1} -n "${GM_NS}" get svc gloo-mesh-mgmt-server-relay-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [[ -n "${RELAY_LB}" ]] && break
  [[ ${i} -eq 36 ]] && fail "Relay LB did not get an address after 3 min"
  sleep 5
done
ok "Relay LB: ${RELAY_LB}"

###############################################################################
# 5. Install Gloo Mesh agent on cluster1 (connects to local management server)
###############################################################################
log "Installing Gloo Mesh agent on cluster1"

AGENT_REGISTRY_FLAGS_C1=""
if [[ -n "${REGISTRY}" ]]; then
  AGENT_REGISTRY_FLAGS_C1="
    --set glooAgent.image.registry=${REGISTRY}/gloo-mesh
    --set telemetryCollector.image.repository=${REGISTRY}/gloo-otel-collector"
fi

# shellcheck disable=SC2086
helm upgrade --install gloo-platform-agent-c1 gloo-platform/gloo-platform \
  --kube-context "${C1}" \
  --namespace "${GM_NS}" \
  --version "${GLOO_VERSION}" \
  --wait --timeout 5m \
  ${AGENT_REGISTRY_FLAGS_C1} \
  -f - <<EOF
common:
  cluster: cluster1

glooAgent:
  enabled: true
  relay:
    serverAddress: "gloo-mesh-mgmt-server:9900"
    clientTlsSecretName: relay-client-tls-secret
    rootTlsSecretName: relay-root-tls-secret

glooMgmtServer:
  enabled: false
glooUi:
  enabled: false
prometheus:
  enabled: false
telemetryGateway:
  enabled: false

telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: gloo-telemetry-gateway.gloo-mesh.svc:4317
EOF

ok "Agent installed on cluster1"

###############################################################################
# 6. Install Gloo Mesh agent on cluster2 (connects to cluster1 relay LB)
###############################################################################
log "Installing Gloo Mesh agent on cluster2 (relay → ${RELAY_LB}:9900)"

AGENT_REGISTRY_FLAGS_C2=""
if [[ -n "${REGISTRY}" ]]; then
  AGENT_REGISTRY_FLAGS_C2="
    --set glooAgent.image.registry=${REGISTRY}/gloo-mesh
    --set telemetryCollector.image.repository=${REGISTRY}/gloo-otel-collector"
fi

# shellcheck disable=SC2086
helm upgrade --install gloo-platform-agent gloo-platform/gloo-platform \
  --kube-context "${C2}" \
  --namespace "${GM_NS}" \
  --version "${GLOO_VERSION}" \
  --wait --timeout 5m \
  ${AGENT_REGISTRY_FLAGS_C2} \
  -f - <<EOF
common:
  cluster: cluster2

glooAgent:
  enabled: true
  relay:
    serverAddress: "${RELAY_LB}:9900"
    clientTlsSecretName: relay-client-tls-secret
    rootTlsSecretName: relay-root-tls-secret

glooMgmtServer:
  enabled: false
glooUi:
  enabled: false
prometheus:
  enabled: false
telemetryGateway:
  enabled: false

telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: ${RELAY_LB}:4317
EOF

ok "Agent installed on cluster2"

###############################################################################
# 7. Verify both clusters are registered
###############################################################################
log "Verifying cluster registration (waiting up to 90s)"

for i in $(seq 1 18); do
  CLUSTERS=$(${KC1} -n "${GM_NS}" get kubernetesclusters 2>/dev/null \
    | grep -c "True" || echo "0")
  [[ "${CLUSTERS}" -ge 2 ]] && { ok "Both clusters registered (${CLUSTERS} KubernetesClusters with Ready=True)"; break; }
  [[ ${i} -eq 18 ]] && {
    echo "  Registered so far:"
    ${KC1} -n "${GM_NS}" get kubernetesclusters 2>/dev/null || true
    echo "  (continuing — clusters may finish registering asynchronously)"
  }
  sleep 5
done

###############################################################################
# 8. Add AgentGateway HTTPRoute for Gloo Mesh UI
###############################################################################
log "Adding AgentGateway route for Gloo Mesh UI (/gloo-mesh)"

${KC1} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: gloo-mesh-ui-backend
  namespace: ${AGW_NS}
spec:
  http:
    targets:
    - name: gloo-mesh-ui
      static:
        host: gloo-mesh-ui.${GM_NS}.svc.cluster.local
        port: 8090
EOF

${KC1} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gloo-mesh-ui-route
  namespace: ${AGW_NS}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NS}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /gloo-mesh
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: gloo-mesh-ui-backend
      namespace: ${AGW_NS}
EOF

ok "AgentGateway route added: /gloo-mesh → gloo-mesh-ui:8090"

###############################################################################
# 9. Summary
###############################################################################
log "Gloo Mesh Enterprise ${GLOO_VERSION} installed"

AGW_LB=$(${KC1} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<agw-lb>")

echo ""
echo "  Management plane:  cluster1 (gloo-mesh namespace)"
echo "  Registered agents: cluster1, cluster2"
echo "  Relay LB:          ${RELAY_LB}:9900"
echo ""
echo "  Access (port-forward):"
echo "    ${KC1} -n ${GM_NS} port-forward svc/gloo-mesh-ui 8090:8090"
echo "    → http://localhost:8090"
echo ""
echo "  Access (via AgentGateway):"
echo "    → http://${AGW_LB}/gloo-mesh"
echo ""
echo "  Helm releases:"
helm list -n "${GM_NS}" --kube-context "${C1}"
echo ""
echo "  Pods:"
${KC1} get pods -n "${GM_NS}"
echo ""

###############################################################################
# 10. Air-gap image list (always printed for reference)
###############################################################################
log "Container images required for air-gapped installation"
echo ""
echo "  Mirror these to your private registry before running in an air-gapped"
echo "  environment. Then set REGISTRY=<your-registry> when running this script."
echo ""
echo "  # Gloo Mesh Enterprise ${GLOO_VERSION}"
cat <<'IMAGELIST'
  gcr.io/gloo-mesh/gloo-mesh-mgmt-server:2.13.0
  gcr.io/gloo-mesh/gloo-mesh-agent:2.13.0
  gcr.io/gloo-mesh/gloo-mesh-ui:2.13.0
  gcr.io/gloo-mesh/gloo-mesh-analyzer:2.13.0
  gcr.io/gloo-mesh/gloo-mesh-apiserver:2.13.0
  gcr.io/gloo-mesh/gloo-mesh-insights:2.13.0
  gcr.io/gloo-mesh/gloo-mesh-envoy:2.13.0
  gcr.io/gloo-mesh/otel-collector:0.2.0
  gcr.io/gloo-mesh/rate-limiter:0.11.7
  gcr.io/gloo-mesh/redis:7.2.4-alpine
  gcr.io/gloo-mesh/prometheus:v2.49.1
  gcr.io/gloo-mesh/opa:0.59.0
  docker.io/bitnami/postgresql:16.1.0-debian-11-r15
  quay.io/brancz/kube-rbac-proxy:v0.14.0
  jimmidyson/configmap-reload:v0.8.0
IMAGELIST
echo ""
echo "  # Gloo Mesh Helm chart (for air-gapped Helm OCI mirror)"
echo "  helm pull gloo-platform/gloo-platform --version ${GLOO_VERSION}"
echo ""
echo "  # Automated image pull (using solo-cop script):"
echo "  curl -sSfL https://raw.githubusercontent.com/solo-io/solo-cop/main/tools/airgap-install/get-image-list | bash -s ${GLOO_VERSION} --pull"
echo ""
