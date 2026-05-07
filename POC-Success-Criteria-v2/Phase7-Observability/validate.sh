#!/usr/bin/env bash
# Phase 7 — Observability: OBS-01 / OBS-02
# Usage: KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase7-Observability/validate.sh
set -euo pipefail

KC_CTX="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KC_CTX}"
AGW_NS="${AGW_NS:-agentgateway-system}"
SEND_TRAFFIC="$(dirname "$0")/../../demo/send-traffic.sh"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
pause() { echo -e "\n  ${B}── press ENTER to continue ──${N}"; read -rp "" _; echo ""; }
step()  { echo -e "\n ${M}━━━ $* ━━━${N}\n"; }
show()  { echo -e "  ${C}\$ $*${N}"; }
ok()    { echo -e "  ${G}✅  $*${N}"; }
warn()  { echo -e "  ${Y}⚠️   $*${N}"; }
note()  { echo -e "\n  ${Y}📋  $*${N}"; }

echo -e "\n${M}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${M}║   Phase 7 — Observability                                ║${N}"
echo -e "${M}║   OBS-01 (cross-cluster traces) · OBS-02 (token usage)   ║${N}"
echo -e "${M}║   Cluster: ${KC_CTX}                                     ║${N}"
echo -e "${M}╚══════════════════════════════════════════════════════════╝${N}"
echo -e "  → Open http://localhost:4000 in another window before starting."
echo -e "  → If port-forward is not running: ./demo/portforward.sh"
pause

###############################################################################
# OBS-01 — Cross-cluster traces
###############################################################################
step "OBS-01 — OTel Distributed Tracing"
show "${KC} -n ${AGW_NS} get enterpriseagentgatewayparameters agentgateway-config -o jsonpath '.spec.rawConfig.config.tracing'"
${KC} -n "${AGW_NS}" get enterpriseagentgatewayparameters agentgateway-config \
  -o jsonpath='{.spec.rawConfig.config.tracing}' 2>/dev/null | python3 -m json.tool 2>/dev/null \
  || warn "EnterpriseAgentgatewayParameters/agentgateway-config not found or no tracing config."
note "otlpEndpoint should point at solo-enterprise-telemetry-collector:4317."
pause

show "${KC} -n ${AGW_NS} logs solo-enterprise-telemetry-collector-0 --tail=20 | grep -iE 'error|fail'"
${KC} -n "${AGW_NS}" logs solo-enterprise-telemetry-collector-0 --tail=30 2>/dev/null \
  | grep -iE "error|fail" | tail -5 || ok "No recent collector errors."
pause

if [[ -x "${SEND_TRAFFIC}" ]]; then
  show "Generate burst: 5 local + 5 remote tools/call"
  for i in 1 2 3 4 5; do
    KUBE_CONTEXT="${KC_CTX}" "${SEND_TRAFFIC}" >/dev/null 2>&1 && echo -n "."
    KUBE_CONTEXT="${KC_CTX}" "${SEND_TRAFFIC}" --remote >/dev/null 2>&1 && echo -n "*"
  done
  echo " done."
else
  warn "demo/send-traffic.sh not found — generate traffic manually."
fi
note "Open http://localhost:4000 → navigate to Traces. The most recent calls
      should appear within ~5-15s. Federated calls show a multi-span tree."
pause

###############################################################################
# OBS-02 — Token Usage / Model Breakdown
###############################################################################
step "OBS-02 — Token Usage & Model Breakdown"
show "${KC} -n ${AGW_NS} get enterpriseagentgatewayparameters agentgateway-config -o jsonpath '.spec.rawConfig.config.metrics'"
${KC} -n "${AGW_NS}" get enterpriseagentgatewayparameters agentgateway-config \
  -o jsonpath='{.spec.rawConfig.config.metrics}' 2>/dev/null | python3 -m json.tool 2>/dev/null \
  || warn "No metrics fields configured."
note "If empty, add metrics.fields.add.user_id and logging.fields for llm.* values
      to surface per-agent and per-model breakdowns in the UI."
pause

if [[ -x "${SEND_TRAFFIC}" ]]; then
  show "Send varied traffic with two different agent IDs"
  AGW_LB=$(${KC} -n "${AGW_NS}" get svc agentgateway-hub \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  if [[ -n "${AGW_LB}" ]]; then
    for agent in agent-a agent-b; do
      for i in 1 2 3 4 5; do
        curl -s -o /dev/null --max-time 3 -X POST "http://${AGW_LB}/mcp" \
          -H "Content-Type: application/json" \
          -H "Accept: application/json, text/event-stream" \
          -H "x-agent-id: ${agent}" \
          -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' || true
      done
      echo "  sent 5 calls as ${agent}"
    done
  fi
fi
note "Open http://localhost:4000 → Sessions / Traffic / Metrics. Filter by
      x-agent-id; per-agent breakdown should populate."
pause

echo -e "\n${G}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${G}║   Phase 7 validation complete ✅                         ║${N}"
echo -e "${G}║                                                          ║${N}"
echo -e "${G}║   OBS-01  Cross-cluster traces in the management UI     ║${N}"
echo -e "${G}║   OBS-02  Per-agent + per-model token breakdown         ║${N}"
echo -e "${G}╚══════════════════════════════════════════════════════════╝${N}\n"
