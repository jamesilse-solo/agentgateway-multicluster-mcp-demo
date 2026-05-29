#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-areg.sh — One-time platform setup for AgentRegistry Enterprise +
#              Virtual Runtime exposure of remote MCP servers via AgentGateway.
#
# What this does (run once, idempotent):
#
#   1. Installs AgentRegistry Enterprise (Helm chart) in agentregistry-system
#   2. Installs arctl (the AR CLI) if not already on PATH
#   3. Labels the existing agentgateway-hub Gateway with
#      `agentregistry.solo.io/runtime=virtual-default` — this is the
#      "name" that joins the gateway to the Virtual Runtime AR seeds at
#      startup
#   4. Applies a parent HTTPRoute `registry-delegate` under PathPrefix
#      `/registry` that delegates every child HTTPRoute the registry
#      generates (name: "*") in the AR install namespace
#   5. Adds `registry-delegate` to the existing oidc-extauth EAGP
#      targetRefs so /registry is OIDC-protected with the same Keycloak
#      JWTs as /mcp
#
# After this finishes, the recipient runs ./scripts/add-mcp.sh to register
# remote MCP servers — no kubectl, no YAML.
#
# Prerequisites:
#   - 01-install.sh + 02-configure.sh + 05-extauth.sh have run
#     (the agentgateway-hub Gateway and oidc-extauth EAGP must already exist)
#
# Usage:
#   ./scripts/04-areg.sh
#   ./scripts/04-areg.sh --cleanup
###############################################################################

# ─── Optional ────────────────────────────────────────────────────────────────
KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AR_NAMESPACE="${AR_NAMESPACE:-agentregistry-system}"
AR_HELM_REPO="${AR_HELM_REPO:-oci://us-docker.pkg.dev/solo-public/agentregistry-enterprise/helm/agentregistry-enterprise}"
AR_VERSION="${AR_VERSION:-2026.5.4}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AGW_GATEWAY_NAME="${AGW_GATEWAY_NAME:-agentgateway-hub}"
RUNTIME_NAME="${RUNTIME_NAME:-virtual-default}"
EXTAUTH_POLICY_NAME="${EXTAUTH_POLICY_NAME:-oidc-extauth}"

KC="kubectl --context ${KUBE_CONTEXT}"
H="helm --kube-context ${KUBE_CONTEXT}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
log()  { echo ""; echo -e "${B}=== $* ===${N}"; }
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
bad()  { echo -e "  ${R}✗${N} $*"; }

# ─── Cleanup ─────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing /registry route + AR Enterprise"
  ${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy "${EXTAUTH_POLICY_NAME}" -o json 2>/dev/null \
    | jq '.spec.targetRefs |= map(select(.name != "registry-delegate"))' \
    | ${KC} apply -f - 2>/dev/null || true
  ${KC} -n "${AR_NAMESPACE}" delete referencegrant registry-delegate-grant --ignore-not-found 2>/dev/null
  ${KC} -n "${AGW_NAMESPACE}" delete httproute registry-delegate --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" label gateway "${AGW_GATEWAY_NAME}" \
    agentregistry.solo.io/runtime- 2>/dev/null || true
  ${H} -n "${AR_NAMESPACE}" uninstall agentregistry 2>/dev/null || true
  ${KC} delete ns "${AR_NAMESPACE}" --wait=false 2>/dev/null || true
  ok "Cleanup complete (AR namespace terminating in background)"
  exit 0
fi

# ─── Sanity ──────────────────────────────────────────────────────────────────
log "Sanity checks"
for bin in kubectl helm curl jq; do
  command -v "${bin}" >/dev/null || { bad "${bin} not on PATH"; exit 1; }
done
ok "kubectl helm curl jq present"

${KC} version --request-timeout=5s -o json >/dev/null \
  || { bad "kubectl --context=${KUBE_CONTEXT} cannot reach the cluster"; exit 1; }
ok "Cluster ${KUBE_CONTEXT} reachable"

${KC} -n "${AGW_NAMESPACE}" get gateway "${AGW_GATEWAY_NAME}" >/dev/null 2>&1 \
  || { bad "Gateway ${AGW_NAMESPACE}/${AGW_GATEWAY_NAME} not found — run 02-configure.sh first"; exit 1; }
ok "Existing gateway ${AGW_GATEWAY_NAME} found"

${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy "${EXTAUTH_POLICY_NAME}" >/dev/null 2>&1 \
  || { bad "EAGP ${EXTAUTH_POLICY_NAME} not found — run 05-extauth.sh first"; exit 1; }
ok "Existing ExtAuth policy ${EXTAUTH_POLICY_NAME} found"

# AGW v2.3.x doesn't honor the `name: "*"` cross-namespace HTTPRoute
# delegation pattern the Virtual Runtime depends on. Refuse to proceed
# if we detect a too-old AGW; point the user at the upgrade script.
AGW_CHART_VERSION=$(${H} -n "${AGW_NAMESPACE}" list -o json 2>/dev/null \
  | jq -r '.[] | select(.name == "enterprise-agentgateway") | .chart' \
  | sed 's/enterprise-agentgateway-//' | head -1)
if [[ -n "${AGW_CHART_VERSION}" ]]; then
  # Accept v2026.x and the unsuffixed 2026.x form.
  if [[ "${AGW_CHART_VERSION}" =~ ^v?20[0-9]{2}\. ]]; then
    ok "AGW Enterprise version: ${AGW_CHART_VERSION} (supports Virtual Runtime)"
  else
    bad "AGW Enterprise version ${AGW_CHART_VERSION} is too old for the Virtual Runtime pattern"
    echo "      Run ./scripts/upgrade-agw.sh to upgrade to v2026.5.x, then re-run this script."
    exit 1
  fi
fi

# ─── 1. Helm install AR Enterprise ───────────────────────────────────────────
log "Installing AgentRegistry Enterprise (${AR_VERSION})"
${KC} create ns "${AR_NAMESPACE}" --dry-run=client -o yaml | ${KC} apply -f - >/dev/null

# AR install is enrolled in the ambient mesh so its traffic gets the same
# mTLS treatment as everything else.
${KC} label ns "${AR_NAMESPACE}" istio.io/dataplane-mode=ambient --overwrite >/dev/null

# AR Enterprise requires either OIDC config or `demoAuthEnabled` set.
# For the POC the API is only reached via port-forward (from this script and
# add-mcp.sh), so demoAuth is sufficient. The user-facing /registry path is
# already OIDC-protected by the existing Keycloak ExtAuth at the AGW LB.
#
# RBAC: autoauth's `admin` client_id mints JWTs with `Groups: ["admins"]`
# (note the capital G). The default roleClaim is `groups` (lowercase),
# which wouldn't match. Map it explicitly so add-mcp.sh's bearer has
# write access to Runtime / MCPServer / Deployment.
${H} upgrade --install agentregistry "${AR_HELM_REPO}" \
  --version "${AR_VERSION}" \
  --namespace "${AR_NAMESPACE}" \
  --set oidc.demoAuthEnabled=true \
  --set oidc.roleClaim=Groups \
  --set oidc.superuserRole=admins \
  --wait --timeout 5m

${KC} -n "${AR_NAMESPACE}" rollout status deploy/agentregistry-enterprise-server --timeout=120s
ok "AR Enterprise running in ${AR_NAMESPACE}"

# ─── 2. arctl install ────────────────────────────────────────────────────────
# The declarative `arctl apply` / `arctl get` commands shipped in v2026.x; the
# v0.x branch supports only `arctl agent`/`mcp`/`deploy`. We always install the
# latest into $HOME/.arctl/bin and prepend that to PATH for this script.
log "Ensuring latest arctl CLI is available"
TARGET_BIN="${HOME}/.arctl/bin/arctl"
NEED_INSTALL="true"
if [[ -x "${TARGET_BIN}" ]] && "${TARGET_BIN}" apply --help >/dev/null 2>&1; then
  NEED_INSTALL="false"
  ok "Latest arctl already installed at ${TARGET_BIN}"
fi
if [[ "${NEED_INSTALL}" == "true" ]]; then
  echo "  Downloading latest arctl via Solo's installer..."
  curl -fsSL https://storage.googleapis.com/agentregistry-enterprise/install.sh \
    | env ARCTL_VERSION=latest sh
  if [[ ! -x "${TARGET_BIN}" ]]; then
    bad "arctl install failed (binary not found at ${TARGET_BIN})"; exit 1
  fi
  ok "arctl installed to ${TARGET_BIN}"
fi
export PATH="${HOME}/.arctl/bin:${PATH}"
case ":${PATH}:" in
  *":${HOME}/.arctl/bin:"*) ;;
  *) warn "For new shells, add to ~/.zshrc:  export PATH=\"\$HOME/.arctl/bin:\$PATH\"" ;;
esac
arctl version 2>&1 | head -1 || true

# ─── 3. Label the existing Gateway so AR's discovery loop picks it up ────────
log "Labeling Gateway ${AGW_GATEWAY_NAME} (agentregistry.solo.io/runtime=${RUNTIME_NAME})"
${KC} -n "${AGW_NAMESPACE}" label gateway "${AGW_GATEWAY_NAME}" \
  "agentregistry.solo.io/runtime=${RUNTIME_NAME}" --overwrite
ok "Gateway labeled"

# ─── 4. Parent HTTPRoute that delegates /registry/* to AR install namespace ──
log "Applying parent HTTPRoute registry-delegate + cross-ns ReferenceGrant"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: registry-delegate
  namespace: ${AGW_NAMESPACE}
  labels:
    agentregistry.solo.io/runtime: ${RUNTIME_NAME}
spec:
  parentRefs:
  - name: ${AGW_GATEWAY_NAME}
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /registry
    backendRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: "*"
      namespace: ${AR_NAMESPACE}
EOF
# Gateway-API requires a ReferenceGrant in the target ns to allow the
# cross-namespace backendRef. Without this the HTTPRoute reports
# ResolvedRefs=False / RefNotPermitted and AR's reconciler refuses to
# write child routes into the AR install ns.
${KC} apply -n "${AR_NAMESPACE}" -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: registry-delegate-grant
  namespace: ${AR_NAMESPACE}
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: ${AGW_NAMESPACE}
  to:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
EOF
ok "HTTPRoute registry-delegate + ReferenceGrant applied"

# ─── 5. Add registry-delegate to oidc-extauth.targetRefs ─────────────────────
log "Attaching registry-delegate to ${EXTAUTH_POLICY_NAME} (so /registry is OIDC-protected)"
if ${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy "${EXTAUTH_POLICY_NAME}" \
    -o jsonpath='{.spec.targetRefs[*].name}' | grep -qw 'registry-delegate'; then
  ok "Already in targetRefs"
else
  ${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy "${EXTAUTH_POLICY_NAME}" \
    --type=json \
    -p='[{"op":"add","path":"/spec/targetRefs/-","value":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"registry-delegate"}}]'
  ok "registry-delegate added"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway "${AGW_GATEWAY_NAME}" \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<gw>')

cat <<EOF

${G}╔════════════════════════════════════════════════════════════════════════╗${N}
${G}║  AgentRegistry + Virtual Runtime ready                                 ║${N}
${G}╚════════════════════════════════════════════════════════════════════════╝${N}

Gateway LB:          http://${AGW_LB}
Registry path:       http://${AGW_LB}/registry/...  (OIDC-protected via Keycloak)
AR install ns:       ${AR_NAMESPACE}
Virtual Runtime:     ${RUNTIME_NAME}  (seeded by AR at startup; no separate apply)

Next steps for the recipient:
  ./scripts/add-mcp.sh search-solo-io https://search.solo.io/mcp
    → registers + waits for Ready + prints the exposed URL

  ./scripts/add-mcp.sh --batch ./scripts/mcps.yaml
    → batch-registers everything in the config file

  ./scripts/remove-mcp.sh search-solo-io
    → removes a single MCP

Reset everything this script did:
  ./scripts/04-areg.sh --cleanup
EOF
