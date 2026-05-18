#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 01-agw-to-agw-federation.sh
#
# WHAT THIS EXAMPLE SHOWS
# -----------------------
# An MCP call enters AgentGateway on Cluster 1. AgentGateway on Cluster 1
# forwards that call to AgentGateway on Cluster 2. Cluster 2's AgentGateway
# then handles the call (its local MCP server responds). The agent on the
# user side only ever talked to Cluster 1 — it does not know Cluster 2
# exists.
#
# This is the "AgentGateway-to-AgentGateway chaining" pattern: from the
# perspective of Cluster 1, Cluster 2's AgentGateway is just another MCP
# upstream. From the perspective of the caller, there is only one gateway.
#
# Why is this useful?
#   - Each cluster's AgentGateway remains the single policy-enforcement
#     point for tools running in that cluster. Cluster 2's policies stay
#     local to Cluster 2, even when the call originated on Cluster 1.
#   - The same Cluster 2 endpoint (/mcp on Cluster 2's AGW) works for
#     external callers and for federated calls from Cluster 1. There is
#     only one configuration to maintain.
#   - It scales: add a third cluster and Cluster 1 just gets one more
#     static upstream entry. No mesh-routing tricks or per-pod plumbing.
#
# WHAT YOU NEED FIRST
# -------------------
# The POC environment must be running:
#   - cluster1 (hub) and cluster2 (spoke) kubectl contexts configured
#   - Istio ambient multicluster peering established (scripts/02-configure.sh
#     on both clusters)
#   - AgentGateway running on both clusters
#   - Dex + ExtAuth running on cluster1 (scripts/05-extauth.sh)
#
# Run this script from a host that has kubectl access to both clusters.
#
# Usage:
#   ./examples/01-agw-to-agw-federation.sh
#
# To remove the example resources afterwards:
#   ./examples/01-agw-to-agw-federation.sh --cleanup
###############################################################################

# ─── Parameters (override via env vars if your setup differs) ─────────────────
CLUSTER1_CONTEXT="${CLUSTER1_CONTEXT:-cluster1}"
CLUSTER2_CONTEXT="${CLUSTER2_CONTEXT:-cluster2}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
PEER_GATEWAY_NAME="${PEER_GATEWAY_NAME:-agentgateway-spoke}"  # cluster2's AGW
PEER_PATH="${PEER_PATH:-/mcp/peer}"                            # new route on cluster1

# Derived
KC1="kubectl --context ${CLUSTER1_CONTEXT}"
KC2="kubectl --context ${CLUSTER2_CONTEXT}"

# Colors — purely for human readability
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
banner() { echo -e "\n${M}━━━ $* ━━━${N}"; }
note()   { echo -e "  ${Y}↳ $*${N}"; }
ok()     { echo -e "  ${G}✓ $*${N}"; }
run()    { echo -e "  ${C}\$ $*${N}"; }

# ─── Cleanup path (--cleanup) ─────────────────────────────────────────────────
if [[ "${1:-}" == "--cleanup" ]]; then
  banner "Removing example resources"
  ${KC1} -n "${AGW_NAMESPACE}" delete httproute mcp-route-peer --ignore-not-found
  ${KC1} -n "${AGW_NAMESPACE}" delete agentgatewaybackend mcp-peer-agw --ignore-not-found
  ${KC2} -n "${AGW_NAMESPACE}" label service "${PEER_GATEWAY_NAME}" \
    solo.io/service-scope- --overwrite 2>/dev/null || true
  ok "Cleanup done — original demo state restored"
  exit 0
fi

###############################################################################
# Step 1 — Make Cluster 2's AgentGateway Service discoverable from Cluster 1
#
# Ambient multicluster does not automatically expose every Service across
# the link. A Service must be explicitly marked as a "global" service. Once
# it is, it appears on the OTHER cluster under the hostname
#   <service-name>.<namespace>.mesh.internal
# and the ambient ztunnel handles cross-cluster routing transparently.
###############################################################################
banner "Step 1 — Expose Cluster 2's AgentGateway as a global service"
note "We label cluster2's '${PEER_GATEWAY_NAME}' Service so it can be"
note "addressed from cluster1 as: ${PEER_GATEWAY_NAME}.${AGW_NAMESPACE}.mesh.internal"
run "kubectl --context ${CLUSTER2_CONTEXT} -n ${AGW_NAMESPACE} label service ${PEER_GATEWAY_NAME} solo.io/service-scope=global --overwrite"
${KC2} -n "${AGW_NAMESPACE}" label service "${PEER_GATEWAY_NAME}" \
  solo.io/service-scope=global --overwrite
ok "Cluster 2's AgentGateway is now reachable across the mesh"

###############################################################################
# Step 2 — On Cluster 1, declare Cluster 2's AgentGateway as an MCP upstream
#
# An AgentgatewayBackend describes a destination that AgentGateway can route
# MCP traffic to. Here the destination is not a tool pod — it is another
# AgentGateway. To AGW-on-Cluster-1, AGW-on-Cluster-2 is "just another MCP
# server" sitting behind a hostname and port. We use a 'static' target with
# a 'path' of /mcp so the chained call lands on Cluster 2's MCP route.
#
# failureMode: FailOpen means: if Cluster 2 is unreachable, do not 500 the
# caller — return what local tools we have. Useful in production; here it
# just shows that AGW knows how to degrade gracefully.
###############################################################################
banner "Step 2 — Add an MCP upstream on Cluster 1 that points at Cluster 2's AGW"
run "kubectl --context ${CLUSTER1_CONTEXT} apply -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-peer-agw
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: cluster2-agw
      static:
        host: ${PEER_GATEWAY_NAME}.${AGW_NAMESPACE}.mesh.internal
        port: 80
        path: /mcp
EOF"
${KC1} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-peer-agw
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: cluster2-agw
      static:
        host: ${PEER_GATEWAY_NAME}.${AGW_NAMESPACE}.mesh.internal
        port: 80
        path: /mcp
EOF
ok "AgentgatewayBackend 'mcp-peer-agw' created on cluster1"

###############################################################################
# Step 3 — On Cluster 1, add a route that exposes the peer AGW under /mcp/peer
#
# Until this exists, the backend we just declared has nowhere to receive
# traffic from. An HTTPRoute attached to the agentgateway-hub Gateway maps
# a URL path on the public load balancer to the backend.
###############################################################################
banner "Step 3 — Route /mcp/peer on Cluster 1 to the peer-AGW backend"
run "kubectl --context ${CLUSTER1_CONTEXT} apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-peer
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${PEER_PATH}
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-peer-agw
      namespace: ${AGW_NAMESPACE}
EOF"
${KC1} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-peer
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${PEER_PATH}
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-peer-agw
      namespace: ${AGW_NAMESPACE}
EOF
ok "HTTPRoute '${PEER_PATH}' wired to the peer-AGW backend"

###############################################################################
# Step 4 — Give the new route the same authentication as the others
#
# The POC protects MCP routes with an OIDC policy that targets
# specific HTTPRoutes by name. We add 'mcp-route-peer' to that list so
# unauthenticated calls to /mcp/peer get the same 302-to-Dex treatment
# as /mcp.
###############################################################################
banner "Step 4 — Add /mcp/peer to the OIDC ExtAuth policy"
note "We patch the existing oidc-extauth policy (created by 05-extauth.sh)"
note "and add mcp-route-peer to its target list."

# Read the current policy, append the new target if not already present.
CURRENT=$(${KC1} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy oidc-extauth \
  -o jsonpath='{.spec.targetRefs}')
if echo "${CURRENT}" | grep -q 'mcp-route-peer'; then
  ok "Policy already targets mcp-route-peer — nothing to do"
else
  ${KC1} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy oidc-extauth \
    --type=json \
    -p='[{"op":"add","path":"/spec/targetRefs/-","value":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"mcp-route-peer"}}]'
  ok "Policy updated"
fi

###############################################################################
# Step 5 — Acquire a JWT and call the federated path
#
# Dex (the demo OIDC provider) is reachable through the AGW hub LB at
# /dex/token. We do the standard OAuth "password grant" to get a Bearer
# token, then POST an MCP 'initialize' to /mcp/peer. The response is
# served by Cluster 2's AGW — but it arrives on Cluster 1's LB just like
# any other MCP response.
###############################################################################
banner "Step 5 — Test it: hit /mcp/peer on Cluster 1 and watch Cluster 2 answer"

AGW_LB=$(${KC1} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
note "AGW Hub LB: ${AGW_LB}"

note "Acquiring a JWT from Dex (via the AGW LB, no port-forward needed)..."
TOKEN=$(curl -s -X POST "http://${AGW_LB}/dex/token" \
  -d 'grant_type=password' \
  -d 'username=demo@example.com' \
  -d 'password=demo-pass' \
  -d 'client_id=agw-client' \
  -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' \
  | jq -r '.id_token')

if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
  echo -e "  ${Y}!! Could not acquire a token. Is Dex / ExtAuth running?${N}"
  exit 1
fi
ok "Token acquired (length ${#TOKEN})"

note "Giving the new route ~5s to propagate through AGW's config plane..."
sleep 5

note "Sending initialize to ${PEER_PATH}..."
run "curl -X POST http://${AGW_LB}${PEER_PATH} -H 'Authorization: Bearer \$TOKEN' ..."
RESP=$(curl -si -X POST "http://${AGW_LB}${PEER_PATH}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}')
STATUS=$(echo "$RESP" | head -1 | awk '{print $2}')
SID=$(echo "$RESP" | grep -i '^mcp-session-id:' | tr -d '\r' | awk '{print $2}')

if [[ "${STATUS}" != "200" ]]; then
  echo -e "  ${Y}!! initialize returned HTTP ${STATUS}${N}"
  echo "${RESP}" | tail -10
  exit 1
fi
ok "initialize returned HTTP 200  (session: ${SID:0:12}...)"

note "Listing tools through the chained AGW..."
TOOLS=$(curl -s -X POST "http://${AGW_LB}${PEER_PATH}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: ${SID}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
COUNT=$(echo "$TOOLS" | grep -o 'data:.*' | head -1 | sed 's/^data: //' | jq -r '.result.tools | length' 2>/dev/null)
ok "tools/list returned ${COUNT} tools — these came from Cluster 2's MCP server,"
ok "  fetched by Cluster 2's AGW, returned to Cluster 1's AGW, then to us."

###############################################################################
# Summary
###############################################################################
banner "What just happened"
cat <<EOF
  $(echo -e ${G}1.${N}) You labeled cluster2's AgentGateway Service as "global" so it became
     addressable from cluster1 via the ambient mesh.
  $(echo -e ${G}2.${N}) On cluster1 you declared cluster2's AgentGateway as an MCP upstream
     — an AgentgatewayBackend with a static host pointing at cluster2.
  $(echo -e ${G}3.${N}) On cluster1 you added the URL path ${PEER_PATH} routing to that backend.
  $(echo -e ${G}4.${N}) You folded the new route into the existing OIDC auth policy.
  $(echo -e ${G}5.${N}) A curl to http://<cluster1-LB>${PEER_PATH} was authenticated by
     cluster1's AGW, forwarded over to cluster2's AGW, served by the MCP
     pod on cluster2, and returned to you — and from the caller's
     perspective there was only ever one gateway.

To remove these resources: ./examples/01-agw-to-agw-federation.sh --cleanup
See examples/01-agw-to-agw-federation.md for a walkthrough with diagrams.
EOF
