#!/usr/bin/env bash
# add-mcp-server.sh — register an MCP server with AgentGateway
#
# Produces an AgentgatewayBackend + HTTPRoute (and ReferenceGrant when the
# backend lives in a different namespace from the gateway). Optionally
# restricts the exposed tool set with toolAllowlist.
#
# Full reference: ./adding-mcp-servers.md
#
# Usage:
#   ./demo/add-mcp-server.sh \
#       --name <id> --path <prefix> --host <host> --port <port> \
#       [--tls] [--backend-namespace <ns>] [--tool-allowlist tool1,tool2,...] \
#       [--dry-run]
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-agentgateway-hub}"

NAME=""; PATH_PREFIX=""; HOST=""; PORT=""
TLS=false; DRY_RUN=false; BACKEND_NS=""; TOOL_ALLOWLIST=""

usage() {
  cat <<EOF
Required:
  --name <id>              Backend + route name (kebab-case)
  --path <prefix>          URL path on the gateway (e.g. /mcp/search)
  --host <host>            Upstream MCP host (DNS or IP)
  --port <port>            Upstream port

Optional:
  --tls                    Upstream uses HTTPS
  --backend-namespace <ns> Place the AgentgatewayBackend in <ns> instead of
                           ${AGW_NAMESPACE}. A ReferenceGrant is created in
                           <ns> permitting HTTPRoutes from ${AGW_NAMESPACE}.
  --tool-allowlist <list>  Comma-separated list of tools to expose. Other
                           tools on the upstream MCP server are hidden from
                           tools/list and rejected on tools/call.
  --dry-run                Print the YAML, don't apply
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)              NAME="$2"; shift 2 ;;
    --path)              PATH_PREFIX="$2"; shift 2 ;;
    --host)              HOST="$2"; shift 2 ;;
    --port)              PORT="$2"; shift 2 ;;
    --tls)               TLS=true; shift ;;
    --backend-namespace) BACKEND_NS="$2"; shift 2 ;;
    --tool-allowlist)    TOOL_ALLOWLIST="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=true; shift ;;
    -h|--help)           usage ;;
    *)                   echo "unknown arg: $1"; usage ;;
  esac
done

[[ -z "${NAME}" || -z "${PATH_PREFIX}" || -z "${HOST}" || -z "${PORT}" ]] && usage

BACKEND_NS="${BACKEND_NS:-${AGW_NAMESPACE}}"
KC="kubectl --context=${KUBE_CONTEXT}"

# AgentgatewayBackend — just the upstream connection details.
# TLS + tool-RBAC live on AgentgatewayPolicy, generated below.
BACKEND=$(cat <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: ${NAME}
  namespace: ${BACKEND_NS}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: ${NAME}
      static:
        host: ${HOST}
        port: ${PORT}
EOF
)

# AgentgatewayPolicy — adds upstream TLS (sni) and per-tool RBAC. Only
# emitted when --tls or --tool-allowlist is set; otherwise omitted.
POLICY=""
if [[ "${TLS}" == "true" || -n "${TOOL_ALLOWLIST}" ]]; then
  TLS_BLOCK=""
  [[ "${TLS}" == "true" ]] && TLS_BLOCK="
    tls:
      sni: ${HOST}"

  AUTHZ_BLOCK=""
  if [[ -n "${TOOL_ALLOWLIST}" ]]; then
    # Build a CEL OR-expression over the requested tool names.
    # Example: name=="search" || name=="get_chunks"
    EXPR=$(echo "${TOOL_ALLOWLIST}" | tr ',' '\n' | sed 's/^/mcp.tool.name == "/;s/$/"/' | paste -sd '|' -)
    EXPR="${EXPR//|/ || }"
    AUTHZ_BLOCK="
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
          - '${EXPR}'"
  fi

  POLICY=$(cat <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: ${NAME}-policy
  namespace: ${BACKEND_NS}
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: ${NAME}
  backend:${TLS_BLOCK}${AUTHZ_BLOCK}
EOF
)
fi

# HTTPRoute (always in the gateway's namespace; backend may be elsewhere)
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
      namespace: ${BACKEND_NS}
EOF
)

# ReferenceGrant — only when cross-namespace
REFGRANT=""
if [[ "${BACKEND_NS}" != "${AGW_NAMESPACE}" ]]; then
  REFGRANT=$(cat <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: ${NAME}-refgrant
  namespace: ${BACKEND_NS}
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: ${AGW_NAMESPACE}
  to:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: ${NAME}
EOF
)
fi

# Combined YAML
COMBINED="${BACKEND}
---
${ROUTE}"
[[ -n "${POLICY}" ]]   && COMBINED="${COMBINED}
---
${POLICY}"
[[ -n "${REFGRANT}" ]] && COMBINED="${COMBINED}
---
${REFGRANT}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "${COMBINED}"
  exit 0
fi

echo "${COMBINED}" | ${KC} apply -f -
echo ""
echo "✓ Applied. Test:"
LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway "${GATEWAY_NAME}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<agw-lb>')
echo "  curl http://${LB}${PATH_PREFIX} ..."
