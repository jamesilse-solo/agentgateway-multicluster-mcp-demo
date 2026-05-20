#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05e-rbac-strict.sh — Strict identity-bound path scoping
#
# Closes the "RBAC + Registry: Partial" gap (the tool-filtering half).
# Without this, any authenticated user could call any tenant's MCP path —
# the tenant-name in the URL was a convention, not enforcement.
#
# Strict mode adds:
#   1. Per-tenant Dex clients (tenant-a-client, tenant-b-client). Each
#      client has its own audience in the issued JWT.
#   2. AgentgatewayPolicy mcp.authentication on each tenant backend that
#      restricts the allowed audiences. Cross-tenant calls (a JWT issued
#      for tenant-a hitting /mcp/tenant-b) are rejected with 401.
#
# AgentRegistry write-API RBAC is left as a follow-up — the registry
# Helm chart needs the OIDC binding switched on which is non-trivial
# state change.
#
# Prerequisites:
#   - 03-dex.sh has run (and the multi-tenant users from PR #2 exist)
#   - 05b-multi-tenancy.sh has run
#
# Usage:
#   ./scripts/05e-rbac-strict.sh
#   ./scripts/05e-rbac-strict.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing strict-RBAC policies"
  for T in tenant-a tenant-b; do
    ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaypolicy "rbac-strict-${T}" --ignore-not-found
  done
  echo "✓ Strict policies removed. Per-tenant Dex clients are left in"
  echo "  dex-config — re-run 03-dex.sh if you want them gone."
  exit 0
fi

###############################################################################
# 1. Patch Dex configmap to add per-tenant clients (each with own audience)
###############################################################################
log "Adding per-tenant Dex clients (tenant-a-client, tenant-b-client)"

CURRENT=$(${KC} -n "${DEX_NAMESPACE}" get configmap dex-config \
  -o jsonpath='{.data.config\.yaml}')

add_client_block() {
  cat <<EOF
    - id: $1
      name: "OAuth client for $2"
      secret: "$1-secret"
      redirectURIs:
      - "http://localhost/callback"
EOF
}

NEW_CONFIG="${CURRENT}"
for CID in tenant-a-client tenant-b-client; do
  if echo "${NEW_CONFIG}" | grep -q "id: ${CID}"; then
    echo "  ${CID} already present — skipping"
  else
    CLIENT_BLOCK=$(add_client_block "${CID}" "${CID%-client}")
    NEW_CONFIG=$(echo "${NEW_CONFIG}" | awk -v add="${CLIENT_BLOCK}" '
      /^    staticClients:/ { in_clients=1; print; next }
      in_clients && /^    [a-zA-Z]/ { print add; in_clients=0 }
      { print }
      END { if (in_clients) print add }
    ')
  fi
done

${KC} -n "${DEX_NAMESPACE}" create configmap dex-config \
  --from-literal=config.yaml="${NEW_CONFIG}" \
  --dry-run=client -o yaml | ${KC} apply -f -
${KC} -n "${DEX_NAMESPACE}" rollout restart deployment/dex
${KC} -n "${DEX_NAMESPACE}" rollout status deployment/dex --timeout=120s

###############################################################################
# 2. Per-tenant authentication restriction
###############################################################################
log "Applying audience-restricted authentication policies"

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
DEX_ISSUER="http://${AGW_LB}/dex"

for T in tenant-a tenant-b; do
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: rbac-strict-${T}
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: mcp-backends-${T}
  backend:
    mcp:
      authentication:
        issuer: "${DEX_ISSUER}"
        audiences:
        - "${T}-client"
EOF
done

log "Strict RBAC applied"
cat <<EOF

Test from a host with kubectl access:
  ./examples/06-rbac-and-registry.sh

To remove:
  ./scripts/05e-rbac-strict.sh --cleanup

What changed:
  - tenant-a-client and tenant-b-client are now valid Dex clients.
  - /mcp/tenant-a only accepts JWTs with aud=tenant-a-client.
  - /mcp/tenant-b only accepts JWTs with aud=tenant-b-client.
  - A tenant-a JWT hitting /mcp/tenant-b → 401.
EOF
