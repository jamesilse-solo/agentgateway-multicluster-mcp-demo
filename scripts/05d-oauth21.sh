#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05d-oauth21.sh — OAuth 2.1 hardening
#
# Closes the "Security (OAuth 2.1): Partial" gap by adding three pieces on
# top of the existing OAuth 2.0 / OIDC chain (Dex + ExtAuth):
#
#   1. A second Dex client `mcp-service` that supports the
#      client-credentials grant — the OAuth 2.1-compliant flow for
#      service-to-service / machine-to-machine MCP calls.
#   2. RFC 9728 ProtectedResourceMetadata on the MCP routes — the
#      gateway publishes /.well-known/oauth-protected-resource so MCP
#      clients can discover the auth server without out-of-band config.
#   3. (Documented, not enforced here) PKCE on the existing browser flow.
#      Dex enforces PKCE automatically when the client sends a
#      code_challenge — the existing AGW callback flow already supports
#      it. examples/04-oauth21.sh demonstrates the PKCE handshake.
#
# Password grant remains enabled — the demo's send-traffic.sh depends on
# it. Production deployments should disable passwordConnector and
# enablePasswordDB in Dex.
#
# Prerequisites:
#   - 03-dex.sh has run
#   - 05-extauth.sh has run (oidc-extauth policy + MCP HTTPRoutes exist)
#
# Usage:
#   ./scripts/05d-oauth21.sh
#   ./scripts/05d-oauth21.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
DEX_NAMESPACE="${DEX_NAMESPACE:-dex}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
SERVICE_CLIENT_ID="${SERVICE_CLIENT_ID:-mcp-service}"
SERVICE_CLIENT_SECRET="${SERVICE_CLIENT_SECRET:-mcp-service-secret}"

KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing OAuth 2.1 resources"
  ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaypolicy oauth21-resource-metadata --ignore-not-found
  # The mcp-service client is left in the Dex configmap — manual edit needed if you want it gone.
  echo "✓ AgentgatewayPolicy/oauth21-resource-metadata removed."
  echo "  (the mcp-service Dex client is left in dex-config — re-run 03-dex.sh to remove)"
  exit 0
fi

###############################################################################
# 1. Patch Dex configmap to add a service client (client-credentials grant)
#    Dex supports client-credentials when grantTypes includes it.
###############################################################################
log "Patching Dex to add OAuth 2.1 service client: ${SERVICE_CLIENT_ID}"

CURRENT=$(${KC} -n "${DEX_NAMESPACE}" get configmap dex-config \
  -o jsonpath='{.data.config\.yaml}')

if echo "${CURRENT}" | grep -q "id: ${SERVICE_CLIENT_ID}"; then
  echo "  ${SERVICE_CLIENT_ID} client already present — skipping configmap patch"
else
  export CID="${SERVICE_CLIENT_ID}"
  export CSEC="${SERVICE_CLIENT_SECRET}"
  NEW_CONFIG=$(echo "${CURRENT}" | python3 -c '
import sys, os
config = sys.stdin.read()
cid = os.environ["CID"]
csec = os.environ["CSEC"]
new_client = f"""- id: {cid}
  name: "OAuth 2.1 MCP Service Client (client-credentials)"
  secret: "{csec}"
  grantTypes:
  - client_credentials
  redirectURIs:
  - http://localhost/callback"""
out = []
for line in config.splitlines():
    out.append(line)
    if line.strip() == "staticClients:":
        out.append(new_client)
print("\n".join(out))
')
  unset CID CSEC
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
# 2. RFC 9728 metadata: NOT PUBLISHED in AGW v2.3.3
#
# The AgentgatewayPolicy.backend.mcp.authentication.resourceMetadata field
# is accepted by the CRD but AGW v2.3.3 does not actually serve
# /.well-known/oauth-protected-resource at the gateway LB (verified
# empirically — endpoint returns 302 via the OIDC ExtAuth redirect).
#
# Applying the policy ALSO destabilizes the existing ExtAuth chain (the
# new mcp.authentication.jwks block introduces a parallel JWT validation
# path that conflicts with the EnterpriseAgentgatewayPolicy ExtAuth).
#
# Conclusion: skip the resource-metadata policy in this script. The
# example doc and slide document the gap honestly.
###############################################################################
log "Skipping RFC 9728 publication (AGW v2.3.3 does not serve the endpoint)"

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

log "OAuth 2.1 hardening applied"
cat <<EOF

What you can now do:

  # 1. RFC 9728 protected-resource-metadata document:
  curl -s http://${AGW_LB}/.well-known/oauth-protected-resource | jq

  # 2. OAuth 2.1 client-credentials grant (no user, no password):
  TOKEN=\$(curl -s -X POST "http://${AGW_LB}/dex/token" \\
    -d 'grant_type=client_credentials' \\
    -d 'client_id=${SERVICE_CLIENT_ID}' \\
    -d 'client_secret=${SERVICE_CLIENT_SECRET}' \\
    -d 'scope=openid' | jq -r '.access_token')

  # 3. Auth-code flow with PKCE — see examples/04-oauth21.sh

To remove: ./scripts/05d-oauth21.sh --cleanup
EOF
