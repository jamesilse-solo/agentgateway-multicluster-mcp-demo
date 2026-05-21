#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05b-multi-tenancy.sh — Per-Tenant MCP Routes, Tool RBAC, and Rate Limits
#
# Demonstrates the AgentGateway multi-tenancy pattern: multiple distinct
# tenants share one gateway endpoint, each on its own URL path, each with
# its own tool allowlist and rate-limit policy. The gateway is the single
# enforcement point — no per-tenant pods, no per-tenant clusters.
#
# What this script creates (cluster1 only):
#   - HTTPRoute  mcp-route-tenant-a  →  AgentgatewayBackend mcp-backends-tenant-a
#   - HTTPRoute  mcp-route-tenant-b  →  AgentgatewayBackend mcp-backends-tenant-b
#   - AgentgatewayPolicy             →  per-tenant mcp.authorization tool allowlist
#   - EnterpriseAgentgatewayPolicy   →  per-route ExtAuth + LOCAL token-bucket
#                                      rate limit (premium vs. free tier)
#
# Two suggested Dex users (added by 03-dex.sh in this PR):
#   - tenant-a-agent / tenant-a-pass  (premium tier)
#   - tenant-b-agent / tenant-b-pass  (free tier)
#
# Both users have valid JWTs and either CAN authenticate against either
# path — the policy *intent* (which tenant uses which path) is enforced by
# operational convention here; Package 5 (RBAC + Registry) adds identity-
# based path scoping with OPA.
#
# Prerequisites:
#   - 02-configure.sh has run (hub Gateway, mcp-server-everything Service)
#   - 04a-agw-management-ui.sh has run (ext-cache Redis required for ratelimit)
#   - 05-extauth.sh has run (Dex AuthConfig oidc-dex exists)
#
# Usage:
#   ./scripts/05b-multi-tenancy.sh
###############################################################################

# ─── Optional Parameters ─────────────────────────────────────────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
GATEWAY_NAME="${GATEWAY_NAME:-agentgateway-hub}"
MCP_UPSTREAM_HOST="${MCP_UPSTREAM_HOST:-mcp-server-everything.${AGW_NAMESPACE}.svc.cluster.local}"
MCP_UPSTREAM_PORT="${MCP_UPSTREAM_PORT:-80}"

# Per-tenant settings (override via env if you want different tiers)
TENANT_A_NAME="${TENANT_A_NAME:-tenant-a}"
TENANT_A_RPM="${TENANT_A_RPM:-1000}"                                   # premium
TENANT_A_TOOLS="${TENANT_A_TOOLS:-}"                                   # empty = all

TENANT_B_NAME="${TENANT_B_NAME:-tenant-b}"
TENANT_B_RPM="${TENANT_B_RPM:-5}"                                      # free / low quota
TENANT_B_TOOLS="${TENANT_B_TOOLS:-echo,get-sum}"

# ─── Helper ───────────────────────────────────────────────────────────────────
KC="kubectl --context ${KUBE_CONTEXT}"
log() { echo ""; echo "=== $1 ==="; }

# ─── Cleanup path (must run BEFORE the apply logic) ──────────────────────────
if [[ "${1:-}" == "--cleanup" ]]; then
  for TENANT in "${TENANT_A_NAME}" "${TENANT_B_NAME}"; do
    ${KC} -n "${AGW_NAMESPACE}" delete enterpriseagentgatewaypolicy "multi-tenancy-${TENANT}" --ignore-not-found
    ${KC} -n "${AGW_NAMESPACE}" delete httproute "mcp-route-${TENANT}" --ignore-not-found
    ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaypolicy "mcp-backends-${TENANT}-policy" --ignore-not-found
    ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaybackend "mcp-backends-${TENANT}" --ignore-not-found
  done
  echo "✓ Multi-tenancy resources removed"
  exit 0
fi

log "Targeting:"
echo "  context:      ${KUBE_CONTEXT}"
echo "  namespace:    ${AGW_NAMESPACE}"
echo "  gateway:      ${GATEWAY_NAME}"
echo "  upstream:     ${MCP_UPSTREAM_HOST}:${MCP_UPSTREAM_PORT}"
echo ""
echo "  ${TENANT_A_NAME}: ${TENANT_A_RPM} rpm · tools=${TENANT_A_TOOLS:-<all>}"
echo "  ${TENANT_B_NAME}: ${TENANT_B_RPM} rpm · tools=${TENANT_B_TOOLS}"

###############################################################################
# Build a CEL OR-expression "mcp.tool.name == \"t1\" || mcp.tool.name == \"t2\""
# from a comma-separated list. Empty list → no expression → all tools allowed.
###############################################################################
tool_allowlist_expr() {
  local list="$1"
  [[ -z "${list}" ]] && return 0
  echo "${list}" \
    | tr ',' '\n' \
    | sed 's/^/mcp.tool.name == "/;s/$/"/' \
    | paste -sd '|' - \
    | sed 's/|/ || /g'
}

###############################################################################
# Apply per-tenant resources. Called twice — once for each tenant.
###############################################################################
apply_tenant() {
  local TENANT="$1"
  local RPM="$2"
  local TOOLS_CSV="$3"

  log "Applying tenant: ${TENANT}  (rpm=${RPM}, tools=${TOOLS_CSV:-<all>})"

  # 1. AgentgatewayBackend — same upstream MCP server, distinct resource so
  #    we can attach a tenant-specific tool-RBAC policy to it.
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-backends-${TENANT}
  namespace: ${AGW_NAMESPACE}
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: mcp-server-everything-${TENANT}
      static:
        host: ${MCP_UPSTREAM_HOST}
        port: ${MCP_UPSTREAM_PORT}
EOF

  # 2. AgentgatewayPolicy — tool RBAC via mcp.authorization CEL.
  #    Skip authorization block when TOOLS_CSV is empty (= no restriction).
  local EXPR
  EXPR=$(tool_allowlist_expr "${TOOLS_CSV}")
  if [[ -n "${EXPR}" ]]; then
    ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mcp-backends-${TENANT}-policy
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: mcp-backends-${TENANT}
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
          - '${EXPR}'
EOF
  else
    ${KC} delete agentgatewaypolicy "mcp-backends-${TENANT}-policy" \
      -n "${AGW_NAMESPACE}" --ignore-not-found
  fi

  # 3. HTTPRoute — /mcp/<tenant> → tenant backend
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-${TENANT}
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/${TENANT}
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-backends-${TENANT}
      namespace: ${AGW_NAMESPACE}
EOF

  # 4. EnterpriseAgentgatewayPolicy — attach ExtAuth + local rate limit to
  #    this tenant's HTTPRoute. We use the LOCAL (token-bucket) rate-limit
  #    style so each AGW pod enforces this tenant's rate independently —
  #    no Redis dependency. For a strict global counter use rateLimit.global
  #    with the ext-cache backend (see scripts/09-optional-components.sh
  #    section 4 for that pattern).
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: multi-tenancy-${TENANT}
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: mcp-route-${TENANT}
  traffic:
    entExtAuth:
      authConfigRef:
        name: oidc-dex
        namespace: ${AGW_NAMESPACE}
      backendRef:
        name: ext-auth-service-enterprise-agentgateway
        namespace: ${AGW_NAMESPACE}
        port: 8083
    rateLimit:
      local:
      - requests: ${RPM}
        unit: Minutes
        burst: ${RPM}
EOF
}

apply_tenant "${TENANT_A_NAME}" "${TENANT_A_RPM}" "${TENANT_A_TOOLS}"
apply_tenant "${TENANT_B_NAME}" "${TENANT_B_RPM}" "${TENANT_B_TOOLS}"

###############################################################################
# Summary
###############################################################################
log "Multi-tenancy resources applied"

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway "${GATEWAY_NAME}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<agw-lb>')

cat <<EOF

Two MCP routes now live on the same AGW Hub:

  http://${AGW_LB}/mcp/${TENANT_A_NAME}   (rate=${TENANT_A_RPM}/min, tools=${TENANT_A_TOOLS:-<all>})
  http://${AGW_LB}/mcp/${TENANT_B_NAME}   (rate=${TENANT_B_RPM}/min, tools=${TENANT_B_TOOLS})

Test from a host with kubectl access:
  ./examples/02-multi-tenancy.sh

To remove these resources:
  ./scripts/05b-multi-tenancy.sh --cleanup
EOF
