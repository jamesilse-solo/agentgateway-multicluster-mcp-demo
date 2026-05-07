#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 06-cross-cluster-mcp.sh — Cross-Cluster MCP Routing
#
# Configures AgentGateway Hub (cluster1) to route MCP traffic to the
# mcp-server-everything instance on cluster2 via the ambient mesh east-west
# gateway, demonstrating Solo's AGW-as-waypoint differentiator.
#
# What it does:
#   Cluster2: Labels mcp-server-everything Service as global (mesh.internal)
#   Cluster1: Adds AgentgatewayBackend + HTTPRoute for the remote MCP target
#
# Run AFTER 02-configure.sh (peering established) and 05-extauth.sh (auth).
#
# Usage:
#   ./06-cross-cluster-mcp.sh
###############################################################################

# ─── Optional Parameters ─────────────────────────────────────────────────────
CLUSTER1_CONTEXT="${CLUSTER1_CONTEXT:-cluster1}"
CLUSTER2_CONTEXT="${CLUSTER2_CONTEXT:-cluster2}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
REMOTE_MCP_HOST="mcp-server-everything.${AGW_NAMESPACE}.mesh.internal"

# ─── Helper ───────────────────────────────────────────────────────────────────
KC1="kubectl --context ${CLUSTER1_CONTEXT}"
KC2="kubectl --context ${CLUSTER2_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

###############################################################################
# 1. Label mcp-server-everything on cluster2 as a global service
###############################################################################
log "Labeling mcp-server-everything on cluster2 as global"
${KC2} -n "${AGW_NAMESPACE}" label service mcp-server-everything \
  solo.io/service-scope=global \
  --overwrite
${KC2} -n "${AGW_NAMESPACE}" annotate service mcp-server-everything \
  networking.istio.io/traffic-distribution=Any \
  --overwrite

echo "Cluster2 service is now discoverable as: ${REMOTE_MCP_HOST}"

###############################################################################
# 2. Add AgentgatewayBackend for the remote MCP server on cluster1
###############################################################################
log "Creating AgentgatewayBackend for remote MCP server on cluster1"
${KC1} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-backends-remote
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: mcp-server-everything-remote
      static:
        host: ${REMOTE_MCP_HOST}
        port: 80
EOF

###############################################################################
# 3. Add HTTPRoute for cross-cluster MCP path on cluster1
#    /mcp/remote → mcp-backends-remote AgentgatewayBackend (cluster2, via mesh)
###############################################################################
log "Creating cross-cluster HTTPRoute on cluster1 hub gateway"
${KC1} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-remote
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/remote
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-backends-remote
      namespace: ${AGW_NAMESPACE}
EOF

# For the failover demo: scale down cluster1 local MCP server to 0 replicas,
# then call /mcp — traffic is automatically routed to cluster2 via the ambient
# east-west gateway (mcp-server-everything.agentgateway-system.mesh.internal).

###############################################################################
# 3b. Reverse direction: cluster2 → cluster1
#     An agent hitting cluster2's spoke gateway at /mcp/remote should be
#     routed to cluster1's mcp-server. This proves the federation is symmetric
#     (true distributed mesh, not hub-and-spoke). Validates POC test FED-02.
#
#     Implementation: cluster2 uses a static host pointing at cluster1's
#     external LoadBalancer hostname. This is simpler than configuring a second
#     mesh.internal entry and works regardless of mesh peering state.
###############################################################################
log "Resolving cluster1's AgentGateway external LB for the reverse-direction route"

C1_LB=""
for i in $(seq 1 30); do
  C1_LB=$(${KC1} -n "${AGW_NAMESPACE}" get svc agentgateway-hub \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [[ -n "${C1_LB}" ]] && break
  sleep 5
done

if [[ -z "${C1_LB}" ]]; then
  echo "  ⚠  Could not resolve cluster1 LB. Skipping reverse-direction setup."
else
  echo "  Cluster1 LB: ${C1_LB}"

  log "Creating AgentgatewayBackend mcp-backends-cluster1 on cluster2 (points at C1 LB)"
  ${KC2} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-backends-cluster1
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: mcp-server-cluster1
      static:
        host: ${C1_LB}
        port: 80
EOF

  log "Creating HTTPRoute mcp-route-cluster1 on cluster2 spoke gateway (/mcp/remote)"
  ${KC2} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-cluster1
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-spoke
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/remote
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-backends-cluster1
      namespace: ${AGW_NAMESPACE}
      weight: 1
EOF
fi

###############################################################################
# 4. Verify global service entry is created by Istio
###############################################################################
log "Checking for global ServiceEntry (may take 30s to propagate)"
sleep 15
echo ""
echo "ServiceEntries in istio-system (cluster1):"
${KC1} get serviceentry -n istio-system 2>/dev/null | grep mcp || echo "(not yet — wait a moment and re-check)"
echo ""
echo "ServiceEntries in istio-system (cluster2):"
${KC2} get serviceentry -n istio-system 2>/dev/null | grep mcp || echo "(not yet — wait a moment and re-check)"

###############################################################################
# 5. Demo validation commands
###############################################################################
log "Cross-cluster MCP routing configured"

echo ""
echo "=== DEMO COMMANDS ==="
echo ""
echo "# Step 1: Port-forward to hub gateway (in a separate terminal)"
echo "  ${KC1} -n ${AGW_NAMESPACE} port-forward svc/agentgateway-hub 8080:80"
echo ""
echo "# Step 2: Get a Dex token (port-forward Dex first in another terminal)"
echo "  ${KC1} -n dex port-forward svc/dex 5556:5556 &"
echo "  TOKEN=\$(curl -s -X POST http://localhost:5556/dex/token \\"
echo "    -d 'grant_type=password&username=demo@example.com&password=demo-pass' \\"
echo "    -d 'client_id=agw-client&client_secret=agw-client-secret&scope=openid+email+profile' \\"
echo "    | jq -r '.access_token')"
echo ""
echo "# Step 3: Call MCP from cluster1 (local)"
echo "  curl -s -H 'Authorization: Bearer \${TOKEN}' http://localhost:8080/mcp"
echo ""
echo "# Step 4: Scale DOWN cluster1 MCP server to force cross-cluster routing"
echo "  ${KC1} -n ${AGW_NAMESPACE} scale deploy mcp-server-everything --replicas=0"
echo ""
echo "# Step 5: Same call now routes to cluster2 via ambient mesh"
echo "  curl -s -H 'Authorization: Bearer \${TOKEN}' http://localhost:8080/mcp"
echo "  # Traffic flows: localhost → AGW Hub (cluster1) → ztunnel → EW GW → ztunnel (cluster2) → mcp-server-everything"
echo ""
echo "# Step 6: Scale cluster1 MCP server back up"
echo "  ${KC1} -n ${AGW_NAMESPACE} scale deploy mcp-server-everything --replicas=1"
echo ""
echo "# Verify cross-cluster route specifically:"
echo "  curl -s -H 'Authorization: Bearer \${TOKEN}' http://localhost:8080/mcp/remote"
