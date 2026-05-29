#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# upgrade-agw.sh — Optional: upgrade AgentGateway Enterprise from v2.3.x
#                   to v2026.5.x in place.
#
# Why this script exists:
#   The Virtual Runtime / AgentRegistry integration in scripts/04-areg.sh
#   uses the `name: "*"` cross-namespace HTTPRoute delegation pattern.
#   AGW Enterprise v2.3.x reports `ResolvedRefs=False reason=RefNotPermitted`
#   on that pattern even when a ReferenceGrant is in place — the "relaxed
#   parent-route overlay" behavior shipped in v2026.5.0.
#
#   This script does an idempotent in-place `helm upgrade` of the two
#   AGW charts (CRDs first, then control plane). Existing
#   EnterpriseAgentgatewayPolicy resources (extAuth, multi-tenancy,
#   ExtProc, OAuth 2.1 metadata) keep working — the CRD diff between
#   v2.3.3 and v2026.5.0 is purely additive (a new `traffic.location`
#   block; existing fields untouched).
#
# Prerequisites:
#   - AGW Enterprise already installed via helm (release name
#     `enterprise-agentgateway`)
#   - AGENTGATEWAY_LICENSE_KEY in env
#
# Usage:
#   AGENTGATEWAY_LICENSE_KEY=<key> ./scripts/upgrade-agw.sh
#
# Re-running this is safe (helm upgrade is idempotent).
###############################################################################

: "${AGENTGATEWAY_LICENSE_KEY:?AGENTGATEWAY_LICENSE_KEY is required}"

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AGW_VERSION_NEW="${AGW_VERSION_NEW:-v2026.5.0}"
AGW_HELM_REPO="${AGW_HELM_REPO:-oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"

KC="kubectl --context ${KUBE_CONTEXT}"
H="helm --kube-context ${KUBE_CONTEXT}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
log()  { echo ""; echo -e "${B}=== $* ===${N}"; }
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
bad()  { echo -e "  ${R}✗${N} $*"; }

# ─── Sanity ──────────────────────────────────────────────────────────────────
log "Sanity checks"
for bin in kubectl helm; do
  command -v "${bin}" >/dev/null || { bad "${bin} not on PATH"; exit 1; }
done
ok "kubectl helm present"

${KC} version --request-timeout=5s -o json >/dev/null \
  || { bad "kubectl --context=${KUBE_CONTEXT} cannot reach the cluster"; exit 1; }

CURRENT_VERSION=$(${H} -n "${AGW_NAMESPACE}" list -o json 2>/dev/null \
  | jq -r '.[] | select(.name == "enterprise-agentgateway") | .chart' \
  | sed 's/enterprise-agentgateway-//')
[[ -n "${CURRENT_VERSION}" ]] || { bad "AGW Enterprise not installed — run scripts/01-install.sh first"; exit 1; }
ok "Current AGW Enterprise version: ${CURRENT_VERSION}"
ok "Target version:                 ${AGW_VERSION_NEW}"

if [[ "${CURRENT_VERSION}" == "${AGW_VERSION_NEW}" || "${CURRENT_VERSION}" == "v${AGW_VERSION_NEW#v}" ]]; then
  ok "Already at ${AGW_VERSION_NEW}; nothing to do."
  exit 0
fi

cat <<EOF

${Y}This will upgrade AGW Enterprise in place:${N}
   ${CURRENT_VERSION}  →  ${AGW_VERSION_NEW}

What the schema diff includes: a new traffic.location block (cookie /
header / queryParameter) — purely additive, existing policies remain
valid. Existing EnterpriseAgentgatewayPolicy resources for ExtAuth,
multi-tenancy, ExtProc guardrails, OAuth 2.1 metadata, and MCP routes
will continue to work without re-apply.

EOF

if [[ -t 0 && "${ASSUME_YES:-}" != "true" ]]; then
  read -rp "Proceed with helm upgrade? [y/N] " yn
  [[ "${yn}" == "y" || "${yn}" == "Y" ]] || { warn "Aborted by user"; exit 1; }
fi

# ─── 1. Upgrade CRDs first ───────────────────────────────────────────────────
log "Upgrading AGW Enterprise CRDs to ${AGW_VERSION_NEW}"
${H} upgrade --install enterprise-agentgateway-crds \
  "${AGW_HELM_REPO}/enterprise-agentgateway-crds" \
  --version "${AGW_VERSION_NEW}" \
  --namespace "${AGW_NAMESPACE}" \
  --wait --timeout 3m
ok "CRDs upgraded"

# ─── 2. Upgrade control plane ────────────────────────────────────────────────
log "Upgrading AGW Enterprise control plane to ${AGW_VERSION_NEW}"
# `--reset-then-reuse-values` (helm 3.14+) merges the new chart's defaults
# with our previous explicit overrides. Without this, new values introduced
# by the upgrade (e.g. v2026.5.0's `monitoring:` block) cause nil-pointer
# template errors.
${H} upgrade --install enterprise-agentgateway \
  "${AGW_HELM_REPO}/enterprise-agentgateway" \
  --version "${AGW_VERSION_NEW}" \
  --namespace "${AGW_NAMESPACE}" \
  --reset-then-reuse-values \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --wait --timeout 5m
ok "Control plane upgraded"

# ─── 3. Wait for the data-plane Gateway to be re-programmed ──────────────────
log "Waiting for Gateways to be Programmed=True after upgrade"
for GW in $(${KC} -n "${AGW_NAMESPACE}" get gateway -o jsonpath='{.items[*].metadata.name}'); do
  for i in $(seq 1 60); do
    P=$(${KC} -n "${AGW_NAMESPACE}" get gateway "${GW}" \
      -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
    [[ "${P}" == "True" ]] && { ok "Gateway/${GW} Programmed=True"; break; }
    sleep 2
  done
done

# ─── 4. Re-touch any HTTPRoute that may have stale ResolvedRefs status ───────
# v2.3.x emitted RefNotPermitted on cross-ns HTTPRoute-to-HTTPRoute backendRefs
# even with a ReferenceGrant. After upgrade, re-evaluation needs a generation
# bump; force one by patching an annotation on each HTTPRoute.
log "Re-evaluating HTTPRoute statuses"
for RT in $(${KC} -n "${AGW_NAMESPACE}" get httproute -o jsonpath='{.items[*].metadata.name}'); do
  ${KC} -n "${AGW_NAMESPACE}" annotate httproute "${RT}" \
    "upgrade-evaluated-at=$(date +%s)" --overwrite >/dev/null
done
sleep 3
ok "HTTPRoute re-evaluation triggered"

# ─── 5. Summary ──────────────────────────────────────────────────────────────
log "Upgrade complete"
${H} -n "${AGW_NAMESPACE}" list 2>&1 | grep enterprise-agentgateway

cat <<EOF

${G}Next:${N}
  - Re-run ./scripts/04-areg.sh   (idempotent; reconfigures the AR side)
  - Re-apply any stuck Deployment in AR:
      ./scripts/add-mcp.sh --batch ./scripts/mcps.yaml
  - Sanity-check existing demo flows:
      ./demo/send-traffic.sh
      ./examples/02-multi-tenancy.sh
      ./examples/04-oauth21.sh
      ./examples/08-extproc-guardrails.sh
EOF
