#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 06b-cluster2-jwt-from-hub.sh — Demo: cluster2 (spoke) validates JWTs issued
#                                  by cluster1 (hub) Keycloak.
#
# Why this script exists
# ----------------------
#   AGW Enterprise validates JWTs by pre-fetching the issuer's JWKS from a
#   ConfigMap. The fetch is done by the AGW *controller* pod (in
#   agentgateway-system), not the data plane. That controller pod is NOT
#   enrolled in the ambient mesh, so it cannot resolve cross-cluster
#   `.mesh.internal` hostnames or HBONE-route to them.
#
#   The controller hardcodes the lookup as `<name>.<ns>.svc.cluster.local:<port>`
#   from `traffic.jwtAuthentication.providers[].jwks.remote.backendRef`. So
#   if you point at a Service that exists only on the hub cluster, the
#   spoke's controller gets NXDOMAIN.
#
#   The fix: stand up a local `keycloak` Service on the spoke with manual
#   Endpoints pointing at the hub's AGW LB IPs (the LB serves /realms/*
#   via the keycloak-route configured in scripts/03b-keycloak.sh). The
#   AGW controller on the spoke then resolves the Service locally, hits
#   the hub LB over plain HTTP, and the JWKS lands in the spoke's
#   enterprise-jwks-store ConfigMap.
#
#   Note: this *does* mean the JWKS fetch traverses the public LB rather
#   than the HBONE mesh. The data-plane mTLS isn't affected — clients
#   still send Bearer JWTs straight to the spoke gateway. Only the
#   controller's bootstrap fetch goes via LB.
#
# What this applies (cluster2):
#
#   - keycloak namespace + Service `keycloak` (port 8080→80) + EndpointSlice
#     pinned to the hub AGW LB IPs (resolved at script run time)
#   - HTTPRoute `mcp-route-jwt-example` matching /mcp-jwt, backendRef
#     mcp-backends (the existing spoke MCP server)
#   - EnterpriseAgentgatewayPolicy `jwt-from-hub-keycloak` with
#     traffic.jwtAuthentication mode=Strict, issuer = hub LB realm URL,
#     audience = agw-client, jwks remote backendRef = keycloak/keycloak:8080
#
# Prerequisites:
#   - cluster2 AGW Enterprise on v2026.5.x (run upgrade-agw.sh first)
#   - cluster1 Keycloak labeled solo.io/service-scope=global so the realm
#     URL on the hub LB is reachable from cluster2 (it is, by default,
#     since the hub LB is public)
#   - cluster1 Keycloak realm has the agw-client audience configured
#
# Usage:
#   ./scripts/06b-cluster2-jwt-from-hub.sh
#   ./scripts/06b-cluster2-jwt-from-hub.sh --cleanup
###############################################################################

HUB_CONTEXT="${HUB_CONTEXT:-cluster1}"
SPOKE_CONTEXT="${SPOKE_CONTEXT:-cluster2}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
HUB_GATEWAY="${HUB_GATEWAY:-agentgateway-hub}"
SPOKE_GATEWAY="${SPOKE_GATEWAY:-agentgateway-spoke}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-agw-client}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
log()  { echo ""; echo -e "${B}=== $* ===${N}"; }
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
bad()  { echo -e "  ${R}✗${N} $*"; }

KC_HUB="kubectl --context ${HUB_CONTEXT}"
KC_SPK="kubectl --context ${SPOKE_CONTEXT}"

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing cluster2 JWT-from-hub demo"
  ${KC_SPK} -n "${AGW_NAMESPACE}" delete enterpriseagentgatewaypolicy jwt-from-hub-keycloak --ignore-not-found
  ${KC_SPK} -n "${AGW_NAMESPACE}" delete httproute mcp-route-jwt-example --ignore-not-found
  ${KC_SPK} -n "${KEYCLOAK_NAMESPACE}" delete endpointslice keycloak-shim --ignore-not-found
  ${KC_SPK} -n "${KEYCLOAK_NAMESPACE}" delete svc keycloak --ignore-not-found
  ok "Cleanup complete"
  exit 0
fi

# ─── Sanity ──────────────────────────────────────────────────────────────────
log "Sanity"
for bin in kubectl dig jq; do command -v "${bin}" >/dev/null \
  || { bad "${bin} not on PATH"; exit 1; }; done
${KC_HUB}  version --request-timeout=5s -o json >/dev/null \
  || { bad "Cannot reach hub context ${HUB_CONTEXT}"; exit 1; }
${KC_SPK}  version --request-timeout=5s -o json >/dev/null \
  || { bad "Cannot reach spoke context ${SPOKE_CONTEXT}"; exit 1; }
ok "Both clusters reachable"

# ─── Get hub AGW LB ──────────────────────────────────────────────────────────
HUB_LB=$(${KC_HUB} -n "${AGW_NAMESPACE}" get gateway "${HUB_GATEWAY}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
[[ -n "${HUB_LB}" ]] || { bad "Hub AGW LB not found"; exit 1; }
ok "Hub AGW LB: ${HUB_LB}"

HUB_LB_IPS=()
while IFS= read -r line; do HUB_LB_IPS+=("${line}"); done < <(dig +short "${HUB_LB}" | head -5)
[[ ${#HUB_LB_IPS[@]} -gt 0 ]] || { bad "Could not resolve ${HUB_LB} to IPs"; exit 1; }
ok "Resolved to ${#HUB_LB_IPS[@]} IP(s): ${HUB_LB_IPS[*]}"

# ─── Build EndpointSlice addresses YAML ──────────────────────────────────────
EP_YAML=""
for ip in "${HUB_LB_IPS[@]}"; do
  EP_YAML+="- addresses: [\"${ip}\"]\n  conditions: {ready: true}\n"
done

# ─── Apply spoke namespace + shim Service + EndpointSlice ────────────────────
log "Applying keycloak-shim Service on cluster2"
${KC_SPK} create ns "${KEYCLOAK_NAMESPACE}" --dry-run=client -o yaml | ${KC_SPK} apply -f - >/dev/null
# Ensure ambient is OFF on this ns — the controller's HTTP client is not
# mesh-enrolled; ambient interception would intercept the hop and cause
# mTLS handshakes against the hub LB (which serves plain HTTP).
${KC_SPK} label ns "${KEYCLOAK_NAMESPACE}" istio.io/dataplane-mode- 2>/dev/null || true

${KC_SPK} apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  ports:
  - name: http
    port: 8080
    targetPort: 80
    protocol: TCP
  type: ClusterIP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: keycloak-shim
  namespace: ${KEYCLOAK_NAMESPACE}
  labels:
    kubernetes.io/service-name: keycloak
addressType: IPv4
ports:
- name: http
  protocol: TCP
  port: 80
endpoints:
$(printf "%b" "${EP_YAML}")
EOF
ok "Service + EndpointSlice applied"

# ─── Apply HTTPRoute + EAGP ──────────────────────────────────────────────────
log "Applying /mcp-jwt HTTPRoute + jwtAuthentication EAGP on cluster2"
${KC_SPK} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-jwt-example
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: ${SPOKE_GATEWAY}
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp-jwt
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-backends
      namespace: ${AGW_NAMESPACE}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jwt-from-hub-keycloak
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: mcp-route-jwt-example
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
      - issuer: http://${HUB_LB}/realms/${KEYCLOAK_REALM}
        audiences:
        - ${OIDC_CLIENT_ID}
        jwks:
          remote:
            backendRef:
              kind: Service
              name: keycloak
              namespace: ${KEYCLOAK_NAMESPACE}
              port: 8080
            jwksPath: /realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs
            cacheDuration: 5m
EOF

# ─── Wait for JWKS fetch ─────────────────────────────────────────────────────
log "Waiting for AGW controller to fetch JWKS (≤60s)"
CM=""
for i in $(seq 1 20); do
  CM=$(${KC_SPK} -n "${AGW_NAMESPACE}" get configmap 2>/dev/null \
    | grep enterprise-jwks-store | awk '{print $1}' | head -1)
  [[ -n "${CM}" ]] && break
  sleep 3
done
if [[ -n "${CM}" ]]; then
  ok "JWKS ConfigMap: ${CM}"
else
  warn "JWKS ConfigMap did not appear — check: ${KC_SPK} -n ${AGW_NAMESPACE} logs deploy/enterprise-agentgateway | grep jwks"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
SPOKE_LB=$(${KC_SPK} -n "${AGW_NAMESPACE}" get gateway "${SPOKE_GATEWAY}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)

cat <<EOF

${G}═══ cluster2 jwtAuthentication ready ═══${N}

  Spoke route:     http://${SPOKE_LB}/mcp-jwt
  Validates:       JWTs issued by  http://${HUB_LB}/realms/${KEYCLOAK_REALM}
  Audience:        ${OIDC_CLIENT_ID}
  Mode:            Strict (Bearer required; no browser-session fallback)

Live test:
  TOK=\$(curl -s -X POST "http://${HUB_LB}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \\
    -d 'grant_type=password&username=demo&password=demo-pass' \\
    -d 'client_id=${OIDC_CLIENT_ID}&client_secret=agw-client-secret' \\
    -d 'scope=openid email profile' | jq -r '.id_token')

  curl -i -H "Authorization: Bearer \${TOK}" \\
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \\
    -X POST "http://${SPOKE_LB}/mcp-jwt" \\
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
         "params":{"protocolVersion":"2024-11-05","capabilities":{},
                   "clientInfo":{"name":"t","version":"1"}}}'

  Without the Bearer:  HTTP 401
  With a tampered Bearer:  HTTP 401
  With a valid Bearer:  HTTP 200 (MCP initialize handshake)

Cleanup:
  ./scripts/06b-cluster2-jwt-from-hub.sh --cleanup
EOF
