#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05c-guardrails.sh — MCP guardrails (what works today + the honest gap)
#
# After implementation review against Solo CRD v2.3.3, the following is
# the *actual* guardrail surface for MCP backends:
#
#   ✅ Tool-name allow/deny via AgentgatewayPolicy.backend.mcp.authorization
#      (CEL with mcp.tool.name available at request time)
#
#   ❌ Built-in PII regex against the request body for MCP backends.
#      The promptGuard field with builtins {Ssn, CreditCard, …} EXISTS in
#      the AgentgatewayPolicy CRD but lives under .spec.backend.ai (only
#      fires on AI/LLM backend types, not on MCP backends). Verified
#      empirically: a promptGuard policy attached to an MCP backend is
#      accepted by the API server but does not engage on MCP traffic.
#
#   ❌ Tool-arguments CEL filtering at request time. The CEL context
#      exposes mcp.tool.arguments only POST-request (not for authorization
#      decisions). See schema/cel.json in the agentgateway OSS repo.
#
#   ✅ External webhook (ExtProc) on MCP routes — the path for arbitrary
#      content-policy enforcement on MCP bodies. The placeholder
#      passthrough lives in scripts/09-optional-components.sh; a real
#      implementation requires F5 Calypso, a custom service, or a vendor
#      backend (Bedrock Guardrails / Azure Content Safety / etc.).
#
# This script applies the CEL tool-name DENY rule — blocking dangerous-
# named tools (delete_database, exfiltrate, drop_*) at the gateway. This
# is the production-ready guardrail you can ship today; PII-on-body
# requires the ExtProc / vendor-backend path.
#
# Prerequisites:
#   - 02-configure.sh has run (mcp-backends exists)
#
# Usage:
#   ./scripts/05c-guardrails.sh
#   ./scripts/05c-guardrails.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

GUARDED_BACKENDS=(
  "mcp-backends"
  "mcp-backends-tenant-a"
  "mcp-backends-tenant-b"
)

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing tool-name deny policies"
  for B in "${GUARDED_BACKENDS[@]}"; do
    ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaypolicy "guardrails-${B}" --ignore-not-found
  done
  echo "✓ Guardrails removed"
  exit 0
fi

log "Applying tool-name DENY policy (blocklist: dangerous tool names)"
for B in "${GUARDED_BACKENDS[@]}"; do
  if ! ${KC} -n "${AGW_NAMESPACE}" get agentgatewaybackend "${B}" >/dev/null 2>&1; then
    echo "  ${B} not present — skipping"
    continue
  fi
  echo "  applying guardrails-${B}"
  # NOTE: AgentgatewayPolicy already allows a single mcp.authorization rule
  # per backend. If a backend already has an Allow rule (e.g. tenant-b in
  # Package 1), we can't add a separate Deny — we'd need to merge them.
  # For backends WITHOUT an existing authorization rule, we apply Deny.
  if ${KC} -n "${AGW_NAMESPACE}" get agentgatewaypolicy "${B}-policy" >/dev/null 2>&1; then
    echo "    (skipped: ${B} already has an mcp.authorization Allow policy from Package 1)"
    continue
  fi
  ${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: guardrails-${B}
  namespace: ${AGW_NAMESPACE}
spec:
  targetRefs:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: ${B}
  backend:
    mcp:
      authorization:
        action: Deny
        policy:
          matchExpressions:
          # Tool-name blocklist. Any tool whose name matches one of these
          # is denied at the gateway with no upstream call.
          - 'mcp.tool.name == "delete_database"'
          - 'mcp.tool.name == "exfiltrate_data"'
          - 'mcp.tool.name == "drop_table"'
          - 'mcp.tool.name.startsWith("admin_")'
EOF
done

log "Tool-name guardrails applied"
cat <<EOF

Test from a host with kubectl access:
  ./examples/03-guardrails.sh

To remove:
  ./scripts/05c-guardrails.sh --cleanup

What this DOES enforce:
  - Calls to any tool named delete_database, exfiltrate_data,
    drop_table, or admin_* are rejected at the gateway.

What this DOES NOT enforce (and why):
  - PII-pattern regex on request bodies (SSN / credit card / etc.) on
    MCP traffic. The promptGuard field is wired for AI backends only;
    for MCP, the path is an ExtProc webhook (see
    scripts/09-optional-components.sh placeholder, or a vendor backend).
  - Tool-arguments value filtering at request time. CEL exposes
    mcp.tool.arguments only post-request.

See examples/03-guardrails.md for the full breakdown.
EOF
