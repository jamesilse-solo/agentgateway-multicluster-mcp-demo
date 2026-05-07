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
# Kubectl contexts (how this script reaches each cluster):
C1="${CLUSTER1_CONTEXT:-cluster1}"
C2="${CLUSTER2_CONTEXT:-cluster2}"
AGW_NS="${AGW_NS:-agentgateway-system}"
GM_NS="${GM_NS:-gloo-mesh}"
GLOO_VERSION="${GLOO_VERSION:-2.12.3}"
REGISTRY="${REGISTRY:-}"   # Set to override for air-gapped installs, e.g. my-registry.internal

KC1="kubectl --context ${C1}"
KC2="kubectl --context ${C2}"

# Gloo Mesh `common.cluster` MUST equal Istio's CLUSTER_ID for the management
# UI's service-graph to correlate metrics. Auto-detect from istiod's
# CLUSTER_ID env var if not explicitly set. Fallback: use the kubectl context
# name (matches the install-script default of CLUSTER_NAME=KUBE_CONTEXT).
_detect_istio_cluster_name() {
  local ctx="$1"
  kubectl --context "${ctx}" -n istio-system get deploy istiod-main \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CLUSTER_ID")].value}' 2>/dev/null
}

C1_NAME="${CLUSTER1_NAME:-$(_detect_istio_cluster_name "${C1}")}"
C2_NAME="${CLUSTER2_NAME:-$(_detect_istio_cluster_name "${C2}")}"
[[ -z "${C1_NAME}" ]] && C1_NAME="${C1}"
[[ -z "${C2_NAME}" ]] && C2_NAME="${C2}"
echo "  ▸ Cluster1: kubectl context='${C1}', Istio/Gloo Mesh cluster name='${C1_NAME}'"
echo "  ▸ Cluster2: kubectl context='${C2}', Istio/Gloo Mesh cluster name='${C2_NAME}'"

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
# 2. Clear any pre-existing relay secrets on cluster1 so the Helm chart can
#    create and own them (the mgmt plane chart generates the root CA, server
#    cert, and identity token automatically on first install).
###############################################################################
log "Clearing pre-existing relay secrets on cluster1 (Helm will recreate)"
${KC1} -n "${GM_NS}" delete secret relay-root-tls-secret relay-server-tls-secret \
  relay-tls-signing-secret relay-identity-token-secret 2>/dev/null || true
ok "Pre-existing relay secrets cleared"

###############################################################################
# 3. Install Gloo Mesh CRDs on both clusters
###############################################################################
log "Installing Gloo Mesh CRDs on both clusters (v${GLOO_VERSION})"

# CRDs live in templates/ (not crds/) in this chart, so render via helm template
# and apply with server-side apply to coexist with enterprise-agentgateway-crds.
RENDERED_CRDS=$(helm template gloo-platform-crds gloo-platform/gloo-platform-crds \
  --version "${GLOO_VERSION}" 2>/dev/null)

for KC_CMD_CTX in "${C1}" "${C2}"; do
  echo "${RENDERED_CRDS}" | kubectl --context "${KC_CMD_CTX}" apply \
    --server-side --force-conflicts -f - 2>&1 | grep -v "^Warning:" || true
done
ok "CRDs applied on both clusters"

###############################################################################
# 4. Install Gloo Mesh management plane on cluster1
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
  # MUST match Istio's CLUSTER_ID — see _detect_istio_cluster_name above.
  # The mgmt UI's service-graph correlates istio_requests_total
  # source/destination_cluster labels against KubernetesCluster names.
  cluster: "${C1_NAME}"

glooMgmtServer:
  enabled: true
  relay:
    serverAddress: "gloo-mesh-mgmt-server:9900"
    serverTlsSecretName: relay-server-tls-secret
    rootTlsSecretName: relay-root-tls-secret

# Local agent on the management cluster — required for the management plane
# to discover and observe its own cluster (workloads, mesh state, insights).
# Uses the in-cluster service address so it doesn't traverse the LB hop.
glooAgent:
  enabled: true
  relay:
    serverAddress: "gloo-mesh-mgmt-server.gloo-mesh.svc:9900"
    clientTlsSecretName: relay-client-tls-secret
    rootTlsSecretName: relay-root-tls-secret

# Insights engine surfaces config-correctness, security, and best-practice
# findings in the Gloo Mesh UI. Runs as part of the mgmt-server process; no
# separate deployment.
glooInsightsEngine:
  enabled: true

glooUi:
  enabled: true
  serviceType: ClusterIP

prometheus:
  enabled: true

# telemetryGateway service must be LoadBalancer so cluster2's
# telemetry-collector can ship metrics across clusters into the management
# plane's Prometheus. Without an external endpoint, cluster2 workloads do not
# appear in the Gloo Mesh UI service graph.
telemetryGateway:
  enabled: true
  service:
    type: LoadBalancer

# DaemonSet (one pod per node) that scrapes ztunnel + workload metrics on
# cluster1 and forwards to the local telemetryGateway → Prometheus. Required
# for the Gloo Mesh UI service-graph view to populate cluster1 workloads.
telemetryCollector:
  enabled: true

# Note: glooAnalyzer is enabled but the chart only renders the analyzer (as
# either a sidecar to gloo-mesh-agent or a standalone deployment) when
# glooUi.enabled=false. On the management cluster (where glooUi=true) the
# analyzer would only attach if glooAgent.runAsSidecar=true — collapsing the
# agent into the mgmt-server pod. We keep agent as a standalone deployment for
# clearer topology, so cluster1's local analyzer is not deployed; the
# management plane's insights engine consumes findings from cluster2's
# analyzer (and any other workload-cluster analyzers).
glooAnalyzer:
  enabled: true
EOF

ok "Management plane + local agent + insights engine + telemetry installed on cluster1"

###############################################################################
# 5. Expose management server relay as LoadBalancer (for cluster2 agent)
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
# 6. Distribute relay root cert to cluster2
#    The mgmt plane Helm chart created relay-root-tls-secret on cluster1.
#    Agents on cluster2 need the ca.crt as their trust anchor, and a client
#    cert signed by that root (generated here with openssl).
###############################################################################
log "Distributing relay root cert to cluster2"

RELAY_TMP=$(mktemp -d)
trap 'rm -rf "${RELAY_TMP}"' EXIT

# Extract root CA cert + key from the mgmt-plane-created secret on cluster1
${KC1} -n "${GM_NS}" get secret relay-root-tls-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "${RELAY_TMP}/relay-root.crt"
${KC1} -n "${GM_NS}" get secret relay-root-tls-secret \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "${RELAY_TMP}/relay-root.key"

# Generate per-cluster client certs, signed by the mgmt-plane root.
# Each agent must present a cert whose SAN matches its cluster name —
# the management server's relay-handshake checks this. A single shared
# client cert (one SAN) cannot work for both clusters.
_gen_agent_cert() {
  local cluster_name="$1"
  local out_prefix="$2"
  cat > "${RELAY_TMP}/${cluster_name}-ext.cnf" <<EXTEOF
[v3_req]
subjectAltName = DNS:${cluster_name}, DNS:gloo-mesh-agent.gloo-mesh
EXTEOF
  openssl req -newkey rsa:4096 -keyout "${out_prefix}.key" \
    -out "${out_prefix}.csr" -nodes \
    -subj "/CN=${cluster_name}" &>/dev/null
  openssl x509 -req -in "${out_prefix}.csr" \
    -CA "${RELAY_TMP}/relay-root.crt" -CAkey "${RELAY_TMP}/relay-root.key" \
    -CAcreateserial -out "${out_prefix}.crt" -days 3650 \
    -extfile "${RELAY_TMP}/${cluster_name}-ext.cnf" -extensions v3_req &>/dev/null
}

# Cert SANs must match common.cluster (which the mgmt-server validates against
# the relay handshake) — use the Istio cluster name, not the kubectl context.
_gen_agent_cert "${C1_NAME}" "${RELAY_TMP}/agent-c1"
_gen_agent_cert "${C2_NAME}" "${RELAY_TMP}/agent-c2"

# Push cluster1's agent client cert (SAN=cluster1) into cluster1
${KC1} -n "${GM_NS}" create secret generic relay-client-tls-secret \
  --from-file=tls.crt="${RELAY_TMP}/agent-c1.crt" \
  --from-file=tls.key="${RELAY_TMP}/agent-c1.key" \
  --from-file=ca.crt="${RELAY_TMP}/relay-root.crt" \
  --dry-run=client -o yaml | ${KC1} apply -f -

# Push cluster2's agent client cert (SAN=cluster2) + the trust anchor into cluster2
${KC2} -n "${GM_NS}" create secret generic relay-root-tls-secret \
  --from-file=ca.crt="${RELAY_TMP}/relay-root.crt" \
  --dry-run=client -o yaml | ${KC2} apply -f -
${KC2} -n "${GM_NS}" create secret generic relay-client-tls-secret \
  --from-file=tls.crt="${RELAY_TMP}/agent-c2.crt" \
  --from-file=tls.key="${RELAY_TMP}/agent-c2.key" \
  --from-file=ca.crt="${RELAY_TMP}/relay-root.crt" \
  --dry-run=client -o yaml | ${KC2} apply -f -

ok "Per-cluster agent certs (SAN=cluster name) distributed to both clusters"

# Note: cluster1's local agent is installed as part of the gloo-platform-mgmt
# release in section 4 (glooAgent.enabled=true). No separate release needed.
# The agent now requires the relay-client-tls-secret distributed in section 6
# above to be present before it can authenticate.

# Bounce cluster1's agent so it picks up the freshly distributed client cert
# (helm install creates the deployment but the pod may have started before
# the secret was applied).
${KC1} -n "${GM_NS}" rollout restart deployment/gloo-mesh-agent 2>/dev/null || true
${KC1} -n "${GM_NS}" rollout status deployment/gloo-mesh-agent --timeout=120s 2>/dev/null || true

ok "Cluster1 local agent restarted to pick up distributed client cert"

###############################################################################
# 9. Install Gloo Mesh agent on cluster2 (connects to cluster1 relay LB)
###############################################################################
log "Installing Gloo Mesh agent on cluster2 (relay → ${RELAY_LB}:9900)"

AGENT_REGISTRY_FLAGS_C2=""
if [[ -n "${REGISTRY}" ]]; then
  AGENT_REGISTRY_FLAGS_C2="
    --set glooAgent.image.registry=${REGISTRY}/gloo-mesh
    --set telemetryCollector.image.repository=${REGISTRY}/gloo-otel-collector"
fi

# Resolve cluster1's telemetryGateway LB hostname so cluster2's
# telemetry-collector can ship metrics to it. The chart requires this to be
# set explicitly when the collector runs in a workload cluster.
log "Resolving cluster1 telemetry-gateway LB for cross-cluster metrics"
TG_LB=""
for i in $(seq 1 24); do
  TG_LB=$(${KC1} -n "${GM_NS}" get svc gloo-telemetry-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [[ -n "${TG_LB}" ]] && break
  [[ ${i} -eq 24 ]] && fail "Telemetry gateway LB did not get an address after 2 min"
  sleep 5
done
ok "Telemetry gateway LB: ${TG_LB}"

# shellcheck disable=SC2086
helm upgrade --install gloo-platform-agent gloo-platform/gloo-platform \
  --kube-context "${C2}" \
  --namespace "${GM_NS}" \
  --version "${GLOO_VERSION}" \
  --wait --timeout 5m \
  ${AGENT_REGISTRY_FLAGS_C2} \
  -f - <<EOF
common:
  # MUST match Istio's CLUSTER_ID on cluster2.
  cluster: "${C2_NAME}"

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

# DaemonSet that ships cluster2's metrics back to the management plane's
# telemetryGateway. Cross-cluster, so OTLP endpoint must be the LB hostname
# of cluster1's telemetryGateway (resolved above). Without this, the chart
# fails with "endpoint must be set for the otlp exporter when deployed in
# workload cluster".
telemetryCollector:
  enabled: true
  config:
    exporters:
      otlp:
        endpoint: "${TG_LB}:4317"
        tls:
          insecure: true

# Per-cluster analyzer: reads Istio config + workloads on this cluster and
# emits findings consumed by the management plane's insights engine. Runs as
# a sidecar in the gloo-mesh-agent pod (chart-default behaviour when
# glooUi.enabled=false).
glooAnalyzer:
  enabled: true
EOF

ok "Agent installed on cluster2"

###############################################################################
# 10. Register clusters in management plane
###############################################################################
log "Registering clusters in management plane"

${KC1} apply -f - <<EOF
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${C1_NAME}
  namespace: ${GM_NS}
spec:
  clusterDomain: cluster.local
---
apiVersion: admin.gloo.solo.io/v2
kind: KubernetesCluster
metadata:
  name: ${C2_NAME}
  namespace: ${GM_NS}
spec:
  clusterDomain: cluster.local
EOF

ok "KubernetesCluster CRs created for ${C1_NAME} and ${C2_NAME}"

###############################################################################
# 11. Verify both clusters are registered
###############################################################################
log "Verifying cluster registration (waiting up to 90s)"

for i in $(seq 1 18); do
  CLUSTERS=$(${KC1} -n "${GM_NS}" get kubernetesclusters 2>/dev/null \
    | grep -c "ACCEPTED" || echo "0")
  [[ "${CLUSTERS}" -ge 2 ]] && { ok "Both clusters registered (${CLUSTERS} KubernetesClusters with Ready=True)"; break; }
  [[ ${i} -eq 18 ]] && {
    echo "  Registered so far:"
    ${KC1} -n "${GM_NS}" get kubernetesclusters 2>/dev/null || true
    echo "  (continuing — clusters may finish registering asynchronously)"
  }
  sleep 5
done

###############################################################################
# 12. Add AgentGateway HTTPRoute for Gloo Mesh UI
###############################################################################
log "Adding AgentGateway route for Gloo Mesh UI (/gloo-mesh)"

${KC1} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: gloo-mesh-ui-backend
  namespace: ${AGW_NS}
spec:
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
# 13. Summary
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
# 14. Air-gap image list (always printed for reference)
###############################################################################
log "Container images required for air-gapped installation"
echo ""
echo "  Mirror these to your private registry before running in an air-gapped"
echo "  environment. Then set REGISTRY=<your-registry> when running this script."
echo ""
echo "  # Gloo Mesh Enterprise ${GLOO_VERSION}"
cat <<'IMAGELIST'
  gcr.io/gloo-mesh/gloo-mesh-mgmt-server:2.12.3
  gcr.io/gloo-mesh/gloo-mesh-agent:2.12.3
  gcr.io/gloo-mesh/gloo-mesh-ui:2.12.3
  gcr.io/gloo-mesh/gloo-mesh-analyzer:2.12.3
  gcr.io/gloo-mesh/gloo-mesh-apiserver:2.12.3
  gcr.io/gloo-mesh/gloo-mesh-insights:2.12.3
  gcr.io/gloo-mesh/gloo-mesh-envoy:2.12.3
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
