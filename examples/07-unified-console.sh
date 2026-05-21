#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 07-unified-console.sh — Sanity-check the unified console is reachable
#
# 1. Confirms the console-ui Deployment is Running.
# 2. Hits http://<agw-lb>/console/ without a token → expects 302 (login redirect).
# 3. With a token → expects 200 and a body containing "AgentGateway Enterprise".
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; M='\033[0;35m'; N='\033[0m'
banner() { echo -e "\n${M}━━━ $* ━━━${N}"; }
note()   { echo -e "  ${Y}↳ $*${N}"; }
ok()     { echo -e "  ${G}✓ $*${N}"; }
bad()    { echo -e "  \033[1;31m✗ $*${N}"; }

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

banner "Step 1 — console-ui pod"
if ${KC} -n "${AGW_NAMESPACE}" get pod -l app=console-ui -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
  ok "console-ui pod is Running"
else
  bad "console-ui pod is not Running. Did you run scripts/04d-unified-console.sh?"
  exit 1
fi

banner "Step 2 — /console without a token (expect 302 to /realms/solo-demo/protocol/openid-connect/auth)"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "http://${AGW_LB}/console/")
[[ "${HTTP}" == "302" ]] && ok "/console/ → 302 (OIDC redirect)" || bad "/console/ → HTTP ${HTTP} (expected 302)"

banner "Step 3 — /console with a Bearer token (expect 200 + console HTML)"
TOKEN=$(curl -s -X POST "http://${AGW_LB}/realms/solo-demo/protocol/openid-connect/token" \
  -d 'grant_type=password' -d 'username=demo' -d 'password=demo-pass' \
  -d 'client_id=agw-client' -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' | jq -r '.id_token')
RESP=$(curl -s -w "\n--HTTP:%{http_code}--" \
  -H "Authorization: Bearer ${TOKEN}" \
  "http://${AGW_LB}/console/")
HTTP=$(echo "${RESP}" | tail -1 | sed 's/^.*--HTTP://;s/--$//')
if [[ "${HTTP}" == "200" ]] && echo "${RESP}" | grep -q "AgentGateway Enterprise"; then
  ok "/console/ → 200, body contains the card grid"
else
  bad "/console/ with token → HTTP ${HTTP}"
fi

banner "Open in browser"
cat <<EOF
  http://${AGW_LB}/console/

  Then in another terminal:
    ./demo/portforward.sh

  The four cards point at localhost:4000 / 8080 / 8090 / 6274 — the ports
  portforward.sh exposes.
EOF
