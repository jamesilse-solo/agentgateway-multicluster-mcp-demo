#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05c-guardrails.sh — Native content guardrails (PII regex via RequestGuard)
#
# Closes the "Schema + Guardrails: Missing" gap in the customer feedback.
# Uses AgentGateway's native RequestGuard / ResponseGuard with the built-in
# regex rules: ssn, creditCard, phoneNumber, email, caSin.
#
# NO custom ExtProc needed — the regex catalogue ships in the gateway. Calls
# whose body matches a guard rule are rejected with HTTP 403 before the
# upstream MCP server is touched.
#
# What this script creates:
#   - AgentgatewayPolicy/guardrails-policy   targets ALL existing MCP routes
#     via the backend chain, with guard.regex rules covering ssn + creditCard
#     and rejection action.
#
# Why on the backend, not the route: the guard field lives on
# AgentgatewayPolicy.backend.mcp.guard in the AGW schema (see
# agentgateway/agentgateway/schema/config.json).
#
# Prerequisites:
#   - 05-extauth.sh has been run (so the MCP routes exist)
#   - 05b-multi-tenancy.sh ideally has been run (Package 1) so the tenant
#     routes/backends exist too
#
# Usage:
#   ./scripts/05c-guardrails.sh
#   ./scripts/05c-guardrails.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

# List of AgentgatewayBackend names to apply the guard policy to. Anything
# in this list gets PII regex enforcement on inbound MCP bodies.
GUARDED_BACKENDS=(
  "mcp-backends"            # /mcp on cluster1 (created by 02-configure.sh)
  "mcp-backends-tenant-a"   # Package 1 — premium tenant
  "mcp-backends-tenant-b"   # Package 1 — free tenant
)

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing guardrails policies"
  for B in "${GUARDED_BACKENDS[@]}"; do
    ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaypolicy "guardrails-${B}" --ignore-not-found
  done
  echo "✓ Guardrails removed"
  exit 0
fi

log "Applying RequestGuard policies (PII regex: ssn + creditCard)"
for B in "${GUARDED_BACKENDS[@]}"; do
  if ! ${KC} -n "${AGW_NAMESPACE}" get agentgatewaybackend "${B}" >/dev/null 2>&1; then
    echo "  ${B} not present — skipping (run the prerequisite install step first)"
    continue
  fi
  echo "  applying guardrails-${B}"
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
      guard:
        request:
          regex:
            action: reject
            rules:
            - builtin: ssn
            - builtin: creditCard
          rejection:
            status: 403
            body: |
              {"jsonrpc":"2.0","error":{"code":-32000,"message":"blocked by content policy (PII detected)"}}
EOF
done

log "Guardrails applied"
echo ""
echo "Test from a host with kubectl access:"
echo "  ./examples/03-guardrails.sh"
echo ""
echo "To remove:"
echo "  ./scripts/05c-guardrails.sh --cleanup"
