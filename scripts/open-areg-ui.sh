#!/usr/bin/env bash
# Port-forward AgentRegistry Enterprise UI and open the browser.
# Enterprise AgentRegistry uses demo auth — log in with any credentials.

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KUBE_CONTEXT}"
AREG_SVC="${AREG_SVC:-agentregistry-agentregistry-enterprise}"

pkill -f "port-forward.*agentregistry.*8080" 2>/dev/null || true

# Enterprise service exposes HTTP UI directly on port 8080
${KC} -n agentregistry port-forward "svc/${AREG_SVC}" 8080:8080 &

echo "AgentRegistry Enterprise UI → http://localhost:8080"
echo "Demo auth enabled — log in with any username/password."
echo "Press Ctrl-C to stop."
wait
