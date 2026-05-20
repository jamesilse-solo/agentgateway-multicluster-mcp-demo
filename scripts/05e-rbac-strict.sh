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

PATCHED=0
NEW_CONFIG="${CURRENT}"
for CID in tenant-a-client tenant-b-client; do
  if echo "${NEW_CONFIG}" | grep -q "id: ${CID}"; then
    echo "  ${CID} already present — skipping"
    continue
  fi
  export CID
  NEW_CONFIG=$(echo "${NEW_CONFIG}" | python3 -c '
import sys, os
config = sys.stdin.read()
cid = os.environ["CID"]
new_client = f"""- id: {cid}
  name: "OAuth client for {cid}"
  secret: "{cid}-secret"
  redirectURIs:
  - "http://localhost/callback"
"""
out = []
for line in config.splitlines():
    out.append(line)
    if line.strip() == "staticClients:":
        out.append(new_client.rstrip())
print("\n".join(out))
')
  PATCHED=1
done
unset CID

if [[ ${PATCHED} -eq 1 ]]; then
  ${KC} -n "${DEX_NAMESPACE}" create configmap dex-config \
    --from-literal=config.yaml="${NEW_CONFIG}" \
    --dry-run=client -o yaml | ${KC} apply -f -
  ${KC} -n "${DEX_NAMESPACE}" rollout restart deployment/dex
  ${KC} -n "${DEX_NAMESPACE}" rollout status deployment/dex --timeout=120s

  # ExtAuth caches Dex's JWKS / discovery doc. Rolling Dex without
  # rolling ExtAuth leaves stale state that causes /mcp Bearer auth
  # to 302-redirect instead of accept. Roll ExtAuth too.
  log "Rolling ExtAuth so its Dex client cache is fresh"
  ${KC} -n "${AGW_NAMESPACE}" rollout restart deploy/ext-auth-service-enterprise-agentgateway
  ${KC} -n "${AGW_NAMESPACE}" rollout status deploy/ext-auth-service-enterprise-agentgateway --timeout=120s
fi

###############################################################################
# 2. Strict audience enforcement — NOT applied in this script
#
# The "correct" enforcement would be an AgentgatewayPolicy with
# backend.mcp.authentication.audiences = ["<tenant>-client"] per tenant.
# That field requires a jwks block (CRD-mandatory in v2.3.3), which
# introduces a parallel JWT-validation path that conflicts with the
# existing EnterpriseAgentgatewayPolicy (oidc-extauth) chain — applying
# it destabilizes /mcp on the cluster.
#
# Production options:
#   A. Per-tenant AuthConfig with audience restriction on the existing
#      EnterpriseAgentgatewayPolicy (AuthConfig.oauth2.oidcAuthorizationCode.
#      validAudiences or equivalent) — clean, no parallel validator.
#   B. OPA bundle wired to ExtAuth that decides path-vs-aud per request.
#
# This script stops at the Dex-client setup. Example 06 demonstrates
# token differentiation (each tenant gets a JWT with a distinct aud)
# and documents the enforcement gap honestly.
###############################################################################
log "Strict cross-tenant enforcement is a documented follow-up (see examples/06)"
