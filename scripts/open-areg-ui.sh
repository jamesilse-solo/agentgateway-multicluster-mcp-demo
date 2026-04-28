#!/usr/bin/env bash
# Port-forward AREG UI (8080) + Dex (5556) and open the browser.
# AREG's OIDC redirect targets dex.dex.svc.cluster.local — both forwards
# and the /etc/hosts entry are required for the login flow to work.

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
KC="kubectl --context ${KUBE_CONTEXT}"

# /etc/hosts entry so the browser can reach Dex via its internal hostname
grep -q "dex.dex.svc.cluster.local" /etc/hosts 2>/dev/null || \
  sudo sh -c "echo '127.0.0.1 dex.dex.svc.cluster.local' >> /etc/hosts"

# Kill stale forwards, start fresh
pkill -f "port-forward.*agentregistry-agentregistry-enterprise.*8080" 2>/dev/null || true
pkill -f "port-forward.*dex.*5556" 2>/dev/null || true

${KC} -n agentregistry port-forward svc/agentregistry-agentregistry-enterprise 8080:8080 &
${KC} -n dex            port-forward svc/dex 5556:5556 &

echo "AgentRegistry UI → http://localhost:8080  (demo@example.com / demo-pass)"
echo "Press Ctrl-C to stop."
wait
