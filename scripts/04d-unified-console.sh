#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04d-unified-console.sh — Single Control Plane (unified console index)
#
# Closes the "Single Control Plane: Partial" gap by exposing ONE URL that
# the operator opens to reach every UI in the POC. The index page itself
# is a small static HTML file served by an Nginx pod at /console behind
# the existing OIDC.
#
# The card links inside point at the standard demo/portforward.sh ports
# on the operator's laptop:
#   - AgentRegistry UI         (localhost:8080)
#   - AgentGateway Enterprise  (localhost:4000)
#   - Gloo Mesh Enterprise     (localhost:8090)
#   - MCP Inspector            (localhost:6274)
#
# Using port-forwards keeps existing demo flow intact. A production
# deployment would expose each UI via its own gateway HTTPRoute instead.
#
# Prerequisites:
#   - 02-configure.sh has run (gateway exists)
#   - 05-extauth.sh has run (oidc-extauth policy exists; we'll bind to it)
#
# Usage:
#   ./scripts/04d-unified-console.sh
#   ./scripts/04d-unified-console.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing unified console"
  ${KC} -n "${AGW_NAMESPACE}" delete httproute console-route --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaybackend console-backend --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete svc console-ui --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete deploy console-ui --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete configmap console-ui --ignore-not-found

  # Remove console-route from oidc-extauth policy targets
  ${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy oidc-extauth -o json 2>/dev/null \
    | jq '.spec.targetRefs |= map(select(.name != "console-route"))' \
    | ${KC} apply -f - 2>/dev/null || true
  echo "✓ Unified console removed"
  exit 0
fi

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

###############################################################################
# 1. Static HTML for the console index
###############################################################################
log "Creating the console index HTML"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: console-ui
  namespace: agentgateway-system
data:
  index.html: |
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Federated AI Agent — Console</title>
    <link href="https://fonts.googleapis.com/css2?family=Figtree:wght@400;600;700&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
      :root { --bg:#151927; --card:#1E2035; --border:rgba(92,97,120,0.25); --purple:#8023C3; --purple-l:#CC85FF; --blue:#20B7F3; --green:#1FEEB3; --text:#fff; --text-sub:#9DA1BD; --text-body:#B5B8CD; }
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background: var(--bg); color: var(--text); font-family: 'Figtree', sans-serif; min-height: 100vh; padding: 3rem 2rem; }
      h1 { font-size: 2.2rem; margin-bottom: 0.5rem; }
      h1 span { color: var(--purple-l); }
      .sub { font-family: 'DM Mono', monospace; color: var(--text-sub); margin-bottom: 2.5rem; font-size: 0.95rem; }
      .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 1rem; max-width: 1400px; }
      a.card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 1.3rem 1.4rem; text-decoration: none; color: var(--text); transition: transform 0.15s, border-color 0.15s; display: block; }
      a.card:hover { transform: translateY(-2px); border-color: var(--purple); }
      a.card .icon { font-size: 1.5rem; margin-bottom: 0.4rem; }
      a.card h3 { font-weight: 600; font-size: 1.05rem; margin-bottom: 0.35rem; }
      a.card p { font-size: 0.85rem; color: var(--text-body); line-height: 1.5; }
      a.card .url { font-family: 'DM Mono', monospace; font-size: 0.72rem; color: var(--purple-l); margin-top: 0.6rem; word-break: break-all; }
      footer { color: var(--text-sub); font-size: 0.78rem; font-family: 'DM Mono', monospace; margin-top: 2.5rem; max-width: 700px; line-height: 1.6; }
    </style>
    </head>
    <body>
    <h1>Federated AI Agent — <span>Console</span></h1>
    <p class="sub">One bookmark. Every UI. Behind the same OIDC.</p>
    <div class="grid">
      <a class="card" href="http://localhost:4000" target="_blank">
        <div class="icon">🛡️</div>
        <h3>AgentGateway Enterprise</h3>
        <p>Per-agent sessions, request traces, auth + rate-limit outcomes, MCP method metrics.</p>
        <div class="url">localhost:4000</div>
      </a>
      <a class="card" href="http://localhost:8080" target="_blank">
        <div class="icon">📚</div>
        <h3>AgentRegistry</h3>
        <p>MCP service catalog. Every registered server in the platform with its schema and endpoint.</p>
        <div class="url">localhost:8080</div>
      </a>
      <a class="card" href="http://localhost:8090" target="_blank">
        <div class="icon">🌐</div>
        <h3>Gloo Mesh Enterprise</h3>
        <p>Cross-cluster topology, service graph, data-plane health for both clusters.</p>
        <div class="url">localhost:8090</div>
      </a>
      <a class="card" href="http://localhost:6274" target="_blank">
        <div class="icon">🔍</div>
        <h3>MCP Inspector</h3>
        <p>Interactive MCP client. Browse tools, run tool calls, debug auth flows against the gateway.</p>
        <div class="url">localhost:6274</div>
      </a>
    </div>
    <footer>
      All four UIs are reached via local port-forwards established by
      <code>./demo/portforward.sh</code>. If a card link does not respond, run
      that script in another terminal.
      <br><br>
      This console page itself is served by the AgentGateway Hub at
      <code>/console</code> and is behind the same OIDC as the rest of the
      protected routes.
    </footer>
    </body>
    </html>
EOF

###############################################################################
# 2. Nginx pod that serves the configmap
###############################################################################
log "Deploying the console nginx pod"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: console-ui
  namespace: agentgateway-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: console-ui
  template:
    metadata:
      labels:
        app: console-ui
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: console-ui
---
apiVersion: v1
kind: Service
metadata:
  name: console-ui
  namespace: agentgateway-system
spec:
  selector:
    app: console-ui
  ports:
  - port: 80
    targetPort: 80
EOF

${KC} -n "${AGW_NAMESPACE}" rollout status deploy/console-ui --timeout=60s

###############################################################################
# 3. AGW backend + HTTPRoute + bind to existing OIDC policy
###############################################################################
log "Wiring console-route under /console"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: console-backend
  namespace: ${AGW_NAMESPACE}
spec:
  static:
    host: console-ui.${AGW_NAMESPACE}.svc.cluster.local
    port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: console-route
  namespace: ${AGW_NAMESPACE}
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: ${AGW_NAMESPACE}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /console
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: console-backend
      namespace: ${AGW_NAMESPACE}
EOF

log "Adding console-route to the OIDC ExtAuth policy"
CURRENT=$(${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy oidc-extauth \
  -o jsonpath='{.spec.targetRefs}')
if echo "${CURRENT}" | grep -q 'console-route'; then
  echo "  Already includes console-route."
else
  ${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy oidc-extauth \
    --type=json \
    -p='[{"op":"add","path":"/spec/targetRefs/-","value":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"console-route"}}]'
fi

log "Unified console live"
cat <<EOF

Open in a browser:

  http://${AGW_LB}/console/

You'll be redirected to Dex login (same as /mcp). Sign in with
demo@example.com / demo-pass and the index page renders with cards
for the four UIs.

NOTE: the four cards link to localhost ports. Run ./demo/portforward.sh
in another terminal so those links resolve.

To remove: ./scripts/04d-unified-console.sh --cleanup
EOF
