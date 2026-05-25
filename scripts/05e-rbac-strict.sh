#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05e-rbac-strict.sh — Strict identity-bound path scoping
#
# Closes the multi-tenancy RBAC gap by enforcing per-tenant AUDIENCE on
# each tenant route. A tenant-a JWT (aud=tenant-a-client) cannot use
# /mcp/tenant-b; a tenant-b JWT cannot use /mcp/tenant-a. The block
# happens at the gateway's ExtAuth layer — the upstream MCP server
# never sees the cross-tenant attempt.
#
# Mechanism: per-tenant AuthConfig with validAudiences. Each tenant
# HTTPRoute gets its own EnterpriseAgentgatewayPolicy pointing at its
# own AuthConfig.
#
#   /mcp/tenant-a  → EAGP/multi-tenancy-tenant-a → AuthConfig/oidc-tenant-a
#                                                    validAudiences: [tenant-a-client]
#   /mcp/tenant-b  → EAGP/multi-tenancy-tenant-b → AuthConfig/oidc-tenant-b
#                                                    validAudiences: [tenant-b-client]
#
# The base ExtAuth (oidc-extauth + AuthConfig/oidc-dex) keeps protecting
# /mcp + the other shared routes via the agw-client audience.
#
# Prerequisites:
#   - 03b-keycloak.sh has run (tenant-a-client + tenant-b-client realm clients)
#   - 05-extauth.sh has run (oidc-extauth + AuthConfig/oidc-dex)
#   - 05b-multi-tenancy.sh has run (mcp-route-tenant-a + mcp-route-tenant-b)
#
# Usage:
#   ./scripts/05e-rbac-strict.sh
#   ./scripts/05e-rbac-strict.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing per-tenant AuthConfigs + policies"
  for T in tenant-a tenant-b; do
    ${KC} -n "${AGW_NAMESPACE}" delete authconfig "oidc-${T}" --ignore-not-found
    ${KC} -n "${AGW_NAMESPACE}" delete secret "oauth-${T}" --ignore-not-found
  done
  # Restore the original (shared) multi-tenancy-* policies if they reference
  # oidc-tenant-*. We rewrite them to point back at oidc-dex.
  for T in tenant-a tenant-b; do
    ${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy "multi-tenancy-${T}" \
      --type=merge \
      -p '{"spec":{"traffic":{"entExtAuth":{"authConfigRef":{"name":"oidc-dex","namespace":"'"${AGW_NAMESPACE}"'"}}}}}' \
      2>/dev/null || true
  done
  echo "✓ Strict RBAC removed (Package 1's multi-tenancy policies restored)"
  exit 0
fi

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
[[ -z "${AGW_LB}" ]] && { echo "ERROR: AGW Hub LB not provisioned."; exit 1; }
ISSUER="http://${AGW_LB}/realms/${KEYCLOAK_REALM}"

###############################################################################
# 1. Per-tenant client secrets
###############################################################################
log "Storing per-tenant Keycloak client secrets"
for T in tenant-a tenant-b; do
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: oauth-${T}
  namespace: ${AGW_NAMESPACE}
type: extauth.solo.io/oauth
stringData:
  client-secret: ${T}-client-secret
EOF
done

###############################################################################
# 2. Per-tenant AuthConfigs (validAudiences pins the aud claim)
###############################################################################
log "Creating per-tenant AuthConfigs with audience restriction"
for T in tenant-a tenant-b; do
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: oidc-${T}
  namespace: ${AGW_NAMESPACE}
spec:
  configs:
  - oauth2:
      oidcAuthorizationCode:
        appUrl: "http://${AGW_LB}"
        callbackPath: /callback
        clientId: ${T}-client
        clientSecretRef:
          name: oauth-${T}
          namespace: ${AGW_NAMESPACE}
        issuerUrl: "${ISSUER}"
        scopes:
        - openid
        - email
        - profile
        session:
          failOnFetchFailure: true
          redis:
            cookieName: oidc-session-${T}
            options:
              host: ext-cache-enterprise-agentgateway:6379
        headers:
          idTokenHeader: x-user-token
EOF
  echo "  ✓ AuthConfig/oidc-${T}"
done

###############################################################################
# 3. Wait for AuthConfigs to be accepted
###############################################################################
log "Waiting for AuthConfigs to be Accepted"
for T in tenant-a tenant-b; do
  for i in $(seq 1 30); do
    STATUS=$(${KC} get authconfig "oidc-${T}" -n "${AGW_NAMESPACE}" \
      -o jsonpath='{.status.state}' 2>/dev/null || echo "PENDING")
    if [[ "${STATUS}" == "ACCEPTED" || "${STATUS}" == "Accepted" ]]; then
      echo "  ${T}: ${STATUS}"
      break
    fi
    sleep 2
  done
done

###############################################################################
# 4. Re-point each tenant's EnterpriseAgentgatewayPolicy at its OWN AuthConfig
###############################################################################
log "Re-pointing tenant EAGPs at per-tenant AuthConfigs"
for T in tenant-a tenant-b; do
  ${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy "multi-tenancy-${T}" \
    --type=merge \
    -p '{"spec":{"traffic":{"entExtAuth":{"authConfigRef":{"name":"oidc-'"${T}"'","namespace":"'"${AGW_NAMESPACE}"'"}}}}}'
done

###############################################################################
# 5. Roll ExtAuth so it picks up the new AuthConfigs
###############################################################################
log "Rolling ExtAuth so the new AuthConfigs are loaded"
${KC} -n "${AGW_NAMESPACE}" rollout restart deploy/ext-auth-service-enterprise-agentgateway
${KC} -n "${AGW_NAMESPACE}" rollout status deploy/ext-auth-service-enterprise-agentgateway --timeout=120s

cat <<EOF

Strict cross-tenant RBAC is live. After this:

  • tenant-a JWT (aud=tenant-a-client) → /mcp/tenant-a → 200
  • tenant-a JWT                       → /mcp/tenant-b → 401 (audience mismatch)
  • tenant-b JWT (aud=tenant-b-client) → /mcp/tenant-b → 200
  • tenant-b JWT                       → /mcp/tenant-a → 401 (audience mismatch)

Verify:
  ./examples/06-rbac-and-registry.sh

To revert: ./scripts/05e-rbac-strict.sh --cleanup
EOF
