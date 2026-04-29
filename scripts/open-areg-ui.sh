#!/usr/bin/env bash
# Port-forward AgentRegistry UI and open the browser.
# OSS AgentRegistry uses anonymous auth — no login required.

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KUBE_CONTEXT}"

pkill -f "port-forward.*agentregistry.*8080" 2>/dev/null || true

# OSS service exposes HTTP on port 12121 (→ container 8080)
${KC} -n agentregistry port-forward svc/agentregistry 8080:12121 &

echo "AgentRegistry UI → http://localhost:8080"
echo "Press Ctrl-C to stop."
wait
