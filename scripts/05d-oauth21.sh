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
  # Append a new staticClients entry. We use awk to insert after the existing
  # staticClients block — the new client follows the same indentation.
  NEW_CLIENT_YAML="    - id: ${SERVICE_CLIENT_ID}
      name: \"OAuth 2.1 MCP Service Client (client-credentials)\"
      secret: \"${SERVICE_CLIENT_SECRET}\"
      grantTypes:
      - client_credentials
      redirectURIs:
      - http://localhost/callback"
  NEW_CONFIG=$(echo "${CURRENT}" | awk -v add="${NEW_CLIENT_YAML}" '
    /^    staticClients:/ { in_clients=1; print; next }
    in_clients && /^    [a-zA-Z]/ { print add; in_clients=0 }
    { print }
    END { if (in_clients) print add }
  ')
  ${KC} -n "${DEX_NAMESPACE}" create configmap dex-config \
    --from-literal=config.yaml="${NEW_CONFIG}" \
    --dry-run=client -o yaml | ${KC} apply -f -
  ${KC} -n "${DEX_NAMESPACE}" rollout restart deployment/dex
  ${KC} -n "${DEX_NAMESPACE}" rollout status deployment/dex --timeout=120s
fi

###############################################################################
# 2. Publish RFC 9728 ProtectedResourceMetadata
#
# We attach this via an AgentgatewayPolicy that targets all the MCP backends.
# When an MCP client receives a 401 from a protected route, the gateway
# responds with WWW-Authenticate: Bearer resource_metadata="<URL>", and the
# URL serves the JSON metadata document.
#
# NOTE: the exact CRD path for resourceMetadata is product-version sensitive.
# This shape matches the AGW OSS schema (LocalMcpAuthentication.resourceMetadata
# in schema/config.json). Adjust to AgentgatewayPolicy.backend.mcp.authentication
# if your CRD nests differently.
###############################################################################
log "Publishing RFC 9728 protected-resource-metadata"

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
DEX_ISSUER="http://${AGW_LB}/dex"

${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: oauth21-resource-metadata
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: mcp-backends
  backend:
    mcp:
      authentication:
        issuer: "${DEX_ISSUER}"
        audiences:
        - "agw-client"
        - "${SERVICE_CLIENT_ID}"
        resourceMetadata:
          resource: "http://${AGW_LB}/mcp"
          authorization_servers:
          - "${DEX_ISSUER}"
          bearer_methods_supported:
          - "header"
          scopes_supported:
          - "openid"
          - "email"
          - "profile"
          resource_documentation: "https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/examples/04-oauth21.md"
EOF

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
