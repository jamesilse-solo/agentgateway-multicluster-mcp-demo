#!/usr/bin/env bash
# add-peer-agw.sh — federate this AgentGateway to a peer AGW in another cluster
#
# Implements the AgentGateway-to-AgentGateway chaining pattern: declares
# the peer cluster's AGW Service as an MCP upstream of this cluster's AGW,
# behind a new HTTPRoute. The peer AGW remains the policy enforcement
# point for its own tools — this cluster only forwards.
#
# Full reference: ../examples/01-agw-to-agw-federation.md
#
# Requires Istio ambient multicluster peering between the two clusters
# (set up by scripts/02-configure.sh). The peer Gateway's Service is
# labeled solo.io/service-scope=global so it's discoverable across the
# mesh as <name>.<ns>.mesh.internal.
#
# Usage:
#   ./demo/add-peer-agw.sh \
#       --peer-context <ctx> \
#       [--name <id>] [--path <prefix>] \
#       [--peer-gateway-name <name>] [--peer-namespace <ns>] \
#       [--no-extauth] [--dry-run]
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-agentgateway-hub}"
EXTAUTH_POLICY="${EXTAUTH_POLICY:-oidc-extauth}"

PEER_CONTEXT=""; PEER_GATEWAY_NAME="agentgateway-spoke"; PEER_NAMESPACE=""
NAME="mcp-peer-agw"; PATH_PREFIX="/mcp/peer"
NO_EXTAUTH=false; DRY_RUN=false

usage() {
  cat <<EOF
Required:
  --peer-context <ctx>       Kubectl context of the peer cluster (the one
                             whose AGW will receive forwarded calls)

Optional:
  --name <id>                Backend + route name on this cluster
                             (default: ${NAME})
  --path <prefix>            URL path on this cluster's gateway that
                             forwards to the peer (default: ${PATH_PREFIX})
  --peer-gateway-name <n>    Name of the peer cluster's Gateway/Service
                             (default: ${PEER_GATEWAY_NAME})
  --peer-namespace <ns>      Namespace of the peer Gateway/Service
                             (default: ${AGW_NAMESPACE})
  --no-extauth               Do not patch the existing ${EXTAUTH_POLICY}
                             policy to cover the new route. Use this if
                             the new route should stay unauthenticated.
  --dry-run                  Print the YAML, don't apply or label

Environment:
  KUBE_CONTEXT      This cluster's context     (default: cluster1)
  AGW_NAMESPACE     AGW namespace on both ends (default: agentgateway-system)
  GATEWAY_NAME      This cluster's Gateway     (default: agentgateway-hub)
  EXTAUTH_POLICY    OIDC policy to patch       (default: oidc-extauth)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer-context)      PEER_CONTEXT="$2"; shift 2 ;;
    --peer-gateway-name) PEER_GATEWAY_NAME="$2"; shift 2 ;;
    --peer-namespace)    PEER_NAMESPACE="$2"; shift 2 ;;
    --name)              NAME="$2"; shift 2 ;;
    --path)              PATH_PREFIX="$2"; shift 2 ;;
    --no-extauth)        NO_EXTAUTH=true; shift ;;
    --dry-run)           DRY_RUN=true; shift ;;
    -h|--help)           usage ;;
    *)                   echo "unknown arg: $1"; usage ;;
  esac
done

[[ -z "${PEER_CONTEXT}" ]] && usage

PEER_NAMESPACE="${PEER_NAMESPACE:-${AGW_NAMESPACE}}"
PEER_HOST="${PEER_GATEWAY_NAME}.${PEER_NAMESPACE}.mesh.internal"
KC="kubectl --context=${KUBE_CONTEXT}"
KC_PEER="kubectl --context=${PEER_CONTEXT}"

# AgentgatewayBackend — points at the peer cluster's AGW Service over the
# ambient mesh. failureMode: FailOpen so a peer outage degrades gracefully.
BACKEND=$(cat <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ${NAME}
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: peer-agw
      static:
        host: ${PEER_HOST}
        port: 80
        path: /mcp
EOF
)

# HTTPRoute on this cluster's Gateway
ROUTE=$(cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${NAME}-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: ${PATH_PREFIX}
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: ${NAME}
      namespace: ${AGW_NAMESPACE}
EOF
)

COMBINED="${BACKEND}
---
${ROUTE}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "# Peer service to label (on ${PEER_CONTEXT}):"
  echo "#   kubectl --context=${PEER_CONTEXT} -n ${PEER_NAMESPACE} \\"
  echo "#     label service ${PEER_GATEWAY_NAME} solo.io/service-scope=global --overwrite"
  echo ""
  echo "${COMBINED}"
  if [[ "${NO_EXTAUTH}" == "false" ]]; then
    echo ""
    echo "# Then patch ${EXTAUTH_POLICY} to add HTTPRoute ${NAME}-route to its targetRefs."
  fi
  exit 0
fi

# 1. Make peer AGW Service globally discoverable via ambient mesh
${KC_PEER} -n "${PEER_NAMESPACE}" label service "${PEER_GATEWAY_NAME}" \
  solo.io/service-scope=global --overwrite

# 2. Apply backend + route on this cluster
echo "${COMBINED}" | ${KC} apply -f -

# 3. Fold the new route into the existing OIDC policy unless --no-extauth
if [[ "${NO_EXTAUTH}" == "false" ]]; then
  if ${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy "${EXTAUTH_POLICY}" >/dev/null 2>&1; then
    CURRENT=$(${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy "${EXTAUTH_POLICY}" \
      -o jsonpath='{.spec.targetRefs}')
    if echo "${CURRENT}" | grep -q "${NAME}-route"; then
      echo "✓ ${EXTAUTH_POLICY} already targets ${NAME}-route"
    else
      ${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy "${EXTAUTH_POLICY}" \
        --type=json \
        -p='[{"op":"add","path":"/spec/targetRefs/-","value":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"'"${NAME}-route"'"}}]'
      echo "✓ ${EXTAUTH_POLICY} patched to cover ${NAME}-route"
    fi
  else
    echo "⚠ ${EXTAUTH_POLICY} not found in ${AGW_NAMESPACE} — new route is UNAUTHENTICATED"
    echo "  (Re-run after 05-extauth.sh, or pass --no-extauth deliberately.)"
  fi
fi

echo ""
LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway "${GATEWAY_NAME}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<agw-lb>')
echo "✓ Applied. Test:"
echo "  curl -X POST http://${LB}${PATH_PREFIX} -H 'Authorization: Bearer \$TOKEN' ..."
echo ""
echo "Path of a call to ${PATH_PREFIX}:"
echo "  client → ${GATEWAY_NAME} (${KUBE_CONTEXT}) → ${PEER_GATEWAY_NAME} (${PEER_CONTEXT}) → MCP tool"
