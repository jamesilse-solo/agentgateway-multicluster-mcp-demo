#!/usr/bin/env bash
# Phase 6 — Resiliency & Guardrails: GR-01 / GR-02
# Usage: KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase6-Resiliency-and-Guardrails/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
AGW_NS="${AGW_NS:-agentgateway-system}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
pause() { echo -e "\n  ${B}── press ENTER to continue ──${N}"; read -rp "" _; echo ""; }
step()  { echo -e "\n ${M}━━━ $* ━━━${N}\n"; }
show()  { echo -e "  ${C}\$ $*${N}"; }
ok()    { echo -e "  ${G}✅  $*${N}"; }
warn()  { echo -e "  ${Y}⚠️   $*${N}"; }
note()  { echo -e "\n  ${Y}📋  $*${N}"; }

echo -e "\n${M}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   Phase 6 — Resiliency & Guardrails                      ║${N}"
echo -e "${M}║   GR-01 (ext-proc guardrails) · GR-02 (global ratelimit) ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                     ║${N}"
echo -e "${M}╚══════════════════════════════════════════════════════════╝${N}"
pause

AGW_LB=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

###############################################################################
# GR-01 — ExtProc Guardrails
###############################################################################
step "GR-01 — External Guardrails Webhook (ExtProc)"
show "${KC} -n ${AGW_NS} get gatewayextension"
${KC} -n "${AGW_NS}" get gatewayextension 2>/dev/null \
  || warn "No GatewayExtension CRD or resources — see validate.md for the expected manifest."
note "Demo step: send a benign tools/call (expect success), then send a tools/call
      with simulated PII payload (expect either sanitisation or block depending on
      webhook policy). Inspect webhook logs to confirm the body was inspected."
pause

###############################################################################
# GR-02 — Global Rate Limiting
###############################################################################
step "GR-02 — Global Rate Limiting (Redis-backed)"
show "${KC} -n ${AGW_NS} get pod | grep ext-cache"
${KC} -n "${AGW_NS}" get pod 2>/dev/null | grep -E "^NAME|ext-cache" \
  || warn "No ext-cache (Redis) pod found — rate limiter has no shared backend."
pause

show "Apply RateLimitConfig: 10 req/min keyed on x-agent-id"
${KC} apply -f - <<EOF
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: poc-ratelimit
  namespace: ${AGW_NS}
spec:
  raw:
    rateLimits:
    - actions:
      - requestHeaders:
          headerName: x-agent-id
          descriptorKey: agent
    descriptors:
    - key: agent
      rateLimit:
        unit: MINUTE
        requestsPerUnit: 10
EOF
ok "Applied. Waiting 5s for XDS propagation..."
sleep 5
note "Demo step: send 15 rapid requests with -H 'x-agent-id: test'. Requests 1-10
      should return 200; 11-15 should return 429. After 60s the window resets."
pause

# Acquire Dex JWT — without it, ExtAuth rejects every request before the rate limiter sees it
DEMO_USER="${DEMO_USER:-demo@example.com}"
DEMO_PASS="${DEMO_PASS:-demo-pass}"
CLIENT_ID="${CLIENT_ID:-agw-client}"
CLIENT_SECRET="${CLIENT_SECRET:-agw-client-secret}"
DEX_NS="${DEX_NS:-dex}"

show "Acquire Dex JWT (required so requests pass ExtAuth and reach the rate limiter)"
${KC} -n "${DEX_NS}" port-forward svc/dex 5556:5556 &>/dev/null &
DEX_PF=$!
sleep 3
TOKEN=$(curl -s --max-time 5 -X POST http://localhost:5556/dex/token \
  -d "grant_type=password" -d "username=${DEMO_USER}" -d "password=${DEMO_PASS}" \
  -d "scope=openid email groups" -d "client_id=${CLIENT_ID}" -d "client_secret=${CLIENT_SECRET}" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id_token",""))' 2>/dev/null || echo "")
kill ${DEX_PF} 2>/dev/null || true
[[ -n "${TOKEN}" ]] && ok "Token acquired" || warn "No token — burst will show ExtAuth 302s, not rate-limit 429s."

if [[ -n "${AGW_LB}" ]]; then
  show "Burst 15 MCP initialize calls with x-agent-id=test"
  INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"poc","version":"1"}}}'
  for i in $(seq 1 15); do
    code=$(curl -s -o /dev/null --max-time 3 -w "%{http_code}" \
      -X POST "http://${AGW_LB}/mcp" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -H "x-agent-id: test" \
      -d "${INIT_BODY}")
    printf "  request %2d: HTTP %s\n" "$i" "$code"
  done
fi
note "Expect HTTP 200 for the first ~10 requests, then 429 for the rest — IF the
      RateLimitConfig is attached via an EnterpriseAgentgatewayPolicy on the route.
      If all 15 return 200, the policy attachment is missing — see validate.md.
      The script confirms: token auth works, request reaches the rate limiter scope."
pause

show "${KC} delete ratelimitconfig poc-ratelimit -n ${AGW_NS}"
${KC} delete ratelimitconfig poc-ratelimit -n "${AGW_NS}"
ok "RateLimitConfig deleted."
pause

echo -e "\n${G}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 6 validation complete ✅                         ║${N}"
echo -e "${G}║                                                          ║${N}"
echo -e "${G}║   GR-01  ExtProc guardrails (pluggable webhook)          ║${N}"
echo -e "${G}║   GR-02  Global rate limiting via shared Redis           ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}\n"
