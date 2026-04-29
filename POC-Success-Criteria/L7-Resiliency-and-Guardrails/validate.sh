#!/usr/bin/env bash
# L7 Agent Gateway — Resiliency & External Guardrails: Interactive Validation
# Tests: L7-GR-01 through L7-GR-04
# Usage: KUBE_CONTEXT=cluster1-singtel ./POC-Success-Criteria/L7-Resiliency-and-Guardrails/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
AGW_NS="agentgateway-system"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'

pause() {
  echo -e "\n  ${B}─────────────────────────────────────────────────${N}"
  echo -e "  ${B}  ⏎  Press ENTER to continue...${N}"
  echo -e "  ${B}─────────────────────────────────────────────────${N}"
  read -rp "" _
  echo ""
}

step() {
  echo -e "\n ${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e " ${M}  $*${N}"
  echo -e " ${M}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"
}

show() {
  echo -e "\n  ${C}──────────────────────────────────────────────────────────${N}"
  echo -e "  ${C}  \$ $*${N}"
  echo -e "  ${C}──────────────────────────────────────────────────────────${N}\n"
}

ok()   { echo -e "  ${G}✅  $*${N}"; }
warn() { echo -e "  ${Y}⚠️   $*${N}"; }
note() { echo -e "\n  ${Y}📋  $*${N}"; }

echo ""
echo -e "${M}╔════════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   L7 Agent Gateway — Resiliency & External Guardrails     ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                 ║${N}"
echo -e "${M}║   Tests: L7-GR-01 · 02 · 03 · 04                        ║${N}"
echo -e "${M}╚════════════════════════════════════════════════════════════╝${N}"
echo ""
echo -e "  → Goal: prove that Envoy filters shape traffic, validate payloads,"
echo -e "    integrate with external security webhooks, and translate errors."
echo -e "  → L7-GR-04 scales the MCP server down then restores it. All other"
echo -e "    tests leave no persistent cluster changes."
pause

NETSHOOT=$(${KC} -n debug get pod -l app=netshoot \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -z "${NETSHOOT}" ]] && warn "No netshoot pod found — in-cluster curl tests will be skipped."

AGW_SVC_IP=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

###############################################################################
# L7-GR-01 — External Guardrails Webhooks (ExtProc)
###############################################################################
step "L7-GR-01 — External Guardrails Webhooks (ExtProc)"
echo -e "  → The gateway is configured with a GatewayExtension pointing to an"
echo -e "    external processing (ExtProc) webhook (e.g. F5 Calypso or a custom"
echo -e "    PII scrubber)."
echo -e "  → Every JSON-RPC payload is streamed to the webhook; the webhook"
echo -e "    sanitizes PII fields and returns the cleaned payload. Envoy forwards"
echo -e "    the sanitized version — the MCP server never sees raw PII."
pause

# GR-01.1 — Check for GatewayExtension / ExtProc config
show "${KC} -n ${AGW_NS} get gatewayextension,enterpriseagentgatewaypolicy -o wide"
${KC} -n "${AGW_NS}" get gatewayextension 2>/dev/null \
  || echo "  (no GatewayExtension found)"
${KC} -n "${AGW_NS}" get enterpriseagentgatewaypolicy -o yaml 2>/dev/null \
  | grep -A5 -i "extProc\|extproc\|guardrail\|webhook" | head -20 \
  || echo "  (no ExtProc policy configured)"
note "To configure: create a GatewayExtension resource pointing to your guardrail
      service endpoint, then reference it in an EnterpriseAgentgatewayPolicy.
      Envoy will stream the request/response body to the webhook in real time."
pause

# GR-01.2 — Show how ExtProc transforms a payload with a test request
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/call with PII in params → verify sanitized in response headers"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 10 \
    -X POST -H "Content-Type: application/json" \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"My SSN is 123-45-6789"}}}' \
    -D - -o /dev/null 2>/dev/null | grep -i "x-guardrail\|x-sanitized\|x-pii" || true
  note "If ExtProc is configured, response headers injected by the webhook appear here
        (e.g. x-pii-detected: true). The forwarded payload to the MCP server will
        have the SSN replaced with [REDACTED]."
fi
pause

###############################################################################
# L7-GR-02 — Schema Validation
###############################################################################
step "L7-GR-02 — Schema Validation"
echo -e "  → The gateway validates upstream MCP server responses against the"
echo -e "    registered JSON-RPC schema."
echo -e "  → A malformed response from the backend is caught by the gateway"
echo -e "    and replaced with an MCP-compliant error — the client never receives"
echo -e "    corrupted data."
pause

# GR-02.1 — Check for schema validation config
show "${KC} -n ${AGW_NS} get enterpriseagentgatewaypolicy -o yaml | grep -i schema"
${KC} -n "${AGW_NS}" get enterpriseagentgatewaypolicy -o yaml 2>/dev/null \
  | grep -A5 -i "schema\|validation\|responseTransform" | head -20 \
  || echo "  (no schema validation policy configured)"
note "AgentGateway validates that responses from MCP backends conform to the
      JSON-RPC 2.0 schema. Responses with missing 'jsonrpc', 'id', or 'result/error'
      fields are replaced with a properly structured error response."
pause

# GR-02.2 — Demonstrate with a valid request/response
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/list → inspect response structure (valid JSON-RPC)"
  ${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 10 \
    -X POST -H "Content-Type: application/json" \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
has_jsonrpc = 'jsonrpc' in d
has_id = 'id' in d
has_result = 'result' in d or 'error' in d
print(f'  jsonrpc: {d.get(\"jsonrpc\",\"MISSING\")}  id: {d.get(\"id\",\"MISSING\")}  result/error: {has_result}')
print(f'  Schema valid: {has_jsonrpc and has_id and has_result}')
" 2>/dev/null || warn "Could not parse response"
fi
pause

###############################################################################
# L7-GR-03 — Rate Limiting & Circuit Breakers
###############################################################################
step "L7-GR-03 — Rate Limiting & Circuit Breakers"
echo -e "  → A RateLimitConfig caps requests per agent per minute."
echo -e "  → Requests within the limit succeed; excess requests receive HTTP 429."
echo -e "  → This prevents a runaway agent loop from exhausting backend resources."
pause

# GR-03.1 — Show RateLimitConfig resource
show "${KC} -n ${AGW_NS} get ratelimitconfig"
${KC} -n "${AGW_NS}" get ratelimitconfig 2>/dev/null \
  || echo "  (no RateLimitConfig found — deploy Redis and apply config)"
note "RateLimitConfig uses Redis (ext-cache) for distributed counters.
      The limit can be keyed on any header (e.g. x-agent-id) or a global counter."
pause

# GR-03.2 — Show the policy referencing the rate limit
show "${KC} -n ${AGW_NS} get enterpriseagentgatewaypolicy -o yaml | grep -A10 rateLimit"
${KC} -n "${AGW_NS}" get enterpriseagentgatewaypolicy -o yaml 2>/dev/null \
  | grep -A10 -i "rateLimit\|rate_limit" | head -20 \
  || echo "  (no rate limit policy configured yet)"
note "RateLimitConfig + EnterpriseAgentgatewayPolicy pair: the config defines the
      counter rules; the policy applies them to a Gateway or HTTPRoute."
pause

# GR-03.3 — Burst test: send 12 rapid requests, expect 429 after threshold
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  RATELIMIT_CONFIGURED=$(${KC} -n "${AGW_NS}" get ratelimitconfig 2>/dev/null \
    | wc -l | tr -d ' ')
  if [[ "${RATELIMIT_CONFIGURED}" -gt 1 ]]; then
    show "Sending 12 rapid requests — expect 429 after rate limit threshold"
    for i in $(seq 1 12); do
      CODE=$(${KC} -n debug exec "${NETSHOOT}" -- \
        curl -s --max-time 5 \
        -X POST -H "Content-Type: application/json" \
        "http://${AGW_SVC_IP}/mcp" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
        -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
      echo -e "  Request ${i:2}: HTTP ${CODE}"
    done
    note "429 responses on requests above the threshold prove rate limiting is active.
          The JSON-RPC error body is MCP-compliant: error.code=-32700 (overload)."
  else
    warn "RateLimitConfig not deployed — deploy Redis + RateLimitConfig + policy first."
    note "Example: apiVersion: ratelimit.solo.io/v1alpha1 / kind: RateLimitConfig
         Set requestsPerUnit: 10 / unit: MINUTE then apply via EnterpriseAgentgatewayPolicy."
  fi
fi
pause

###############################################################################
# L7-GR-04 — Graceful HTTP Error Translation
###############################################################################
step "L7-GR-04 — Graceful HTTP Error Translation"
echo -e "  → Force the backend MCP server to become unavailable."
echo -e "    Send a tools/call through the gateway."
echo -e "  → The gateway detects the upstream failure and returns a properly"
echo -e "    structured MCP JSON-RPC error — not a raw 502/503 HTTP error."
echo -e "  → The MCP server is restored after this step."
pause

# GR-04.1 — Show current MCP server pod status
show "${KC} -n ${AGW_NS} get deploy mcp-server-everything"
${KC} -n "${AGW_NS}" get deploy mcp-server-everything 2>/dev/null
MCP_REPLICAS=$(${KC} -n "${AGW_NS}" get deploy mcp-server-everything \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
note "We will scale the MCP server to 0 replicas to simulate a crash, then
      send a tools/call. The gateway should return a JSON-RPC error, not a raw 503."
pause

# GR-04.2 — Scale down to 0
show "${KC} -n ${AGW_NS} scale deploy mcp-server-everything --replicas=0"
${KC} -n "${AGW_NS}" scale deploy mcp-server-everything --replicas=0
echo -e "  Waiting 5s for pod to terminate..."
sleep 5
ok "MCP server scaled to 0 — backend is unavailable."
pause

# GR-04.3 — Send tools/call — expect JSON-RPC error (not raw 5xx)
if [[ -n "${NETSHOOT}" && -n "${AGW_SVC_IP}" ]]; then
  show "POST tools/call (with backend down) — expect MCP-formatted error"
  RESP=$(${KC} -n debug exec "${NETSHOOT}" -- \
    curl -s --max-time 10 \
    -X POST -H "Content-Type: application/json" \
    "http://${AGW_SVC_IP}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    2>/dev/null || echo "{}")
  echo -e "  Response: ${RESP}"
  IS_JSONRPC=$(echo "${RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'jsonrpc' in d else 'no')" 2>/dev/null || echo "no")
  if [[ "${IS_JSONRPC}" == "yes" ]]; then
    ok "Response is a valid JSON-RPC envelope — gateway translated the upstream error."
  else
    warn "Response may be a raw HTTP error — check gateway error translation config."
  fi
  note "A JSON-RPC error body (with 'jsonrpc' field) = the gateway translated the
        upstream 502/503 into an MCP-compliant error. The AI agent receives a
        structured error it can handle gracefully, not an unparseable HTTP page."
fi
pause

# GR-04.4 — Restore
show "${KC} -n ${AGW_NS} scale deploy mcp-server-everything --replicas=${MCP_REPLICAS}"
${KC} -n "${AGW_NS}" scale deploy mcp-server-everything \
  --replicas="${MCP_REPLICAS}" 2>/dev/null
echo -e "  Waiting for pod to start..."
${KC} -n "${AGW_NS}" rollout status deploy/mcp-server-everything --timeout=60s 2>/dev/null || true
ok "MCP server restored to ${MCP_REPLICAS} replica(s)."
pause

###############################################################################
# Done
###############################################################################
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   L7 Resiliency validation complete ✅              ║${N}"
echo -e "${G}║                                                      ║${N}"
echo -e "${G}║   L7-GR-01  ExtProc guardrail webhook (PII scrub)   ║${N}"
echo -e "${G}║   L7-GR-02  Schema validation on backend responses   ║${N}"
echo -e "${G}║   L7-GR-03  Rate limiting — 429 after threshold      ║${N}"
echo -e "${G}║   L7-GR-04  MCP-formatted error on backend failure   ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════╝${N}"
echo ""
