#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04e-visible-identity.sh — Visible Identity console (Package 7)
#
# Replaces the Nginx-served static console (04d-unified-console.sh) with a
# small Python http.server pod that ALSO serves an MCP-aware identity page.
#
# What the user sees after logging in via Keycloak:
#   - Their identity: username, email, JWT claims (aud, groups, team, …)
#   - The MCP tools they CAN call (live tools/list filtered by policy)
#   - The original card grid for AGW UI / Registry / Gloo Mesh / Inspector
#
# This addresses Nikhil's 5/18 feedback: the gateway's policy enforcement
# is invisible at the user surface. Now a presenter can log in twice (as
# demo, then as tenant-b-agent) and the panel changes — same gateway,
# different identity → different tools.
#
# Prerequisites:
#   - 02-configure.sh (Gateway exists)
#   - 05-extauth.sh with IDP=keycloak (so x-user-token header is injected)
#
# Usage:
#   ./scripts/04e-visible-identity.sh
#   ./scripts/04e-visible-identity.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing visible-identity console"
  ${KC} -n "${AGW_NAMESPACE}" delete httproute console-route --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete agentgatewaybackend console-backend --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete svc console-ui --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete deploy console-ui --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete configmap console-ui --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy oidc-extauth -o json 2>/dev/null \
    | jq '.spec.targetRefs |= map(select(.name != "console-route"))' \
    | ${KC} apply -f - 2>/dev/null || true
  echo "✓ Console removed"
  exit 0
fi

AGW_LB=$(${KC} -n "${AGW_NAMESPACE}" get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

###############################################################################
# 1. ConfigMap: Python server + HTML template
###############################################################################
log "Creating console-ui ConfigMap (Python server)"

# Write the Python server to a temp file first so heredocs don't fight bash
SERVER_PY=$(cat <<'PY'
#!/usr/bin/env python3
"""Visible-Identity console — small http.server that renders the user's
JWT claims and accessible MCP tool list."""
import base64, json, os, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer

AGW_INTERNAL = os.environ.get("AGW_INTERNAL",
    "http://agentgateway-hub.agentgateway-system.svc.cluster.local")
MCP_PATH = os.environ.get("MCP_PATH", "/mcp")


def _pad(s):
    return s + "=" * (-len(s) % 4)


def decode_jwt(b64_token):
    if not b64_token:
        return None
    parts = b64_token.split(".")
    if len(parts) != 3:
        return None
    try:
        return json.loads(base64.urlsafe_b64decode(_pad(parts[1])).decode())
    except Exception:
        return None


def fetch_tools(bearer, path="/mcp"):
    if not bearer:
        return None, "no JWT (ExtAuth did not inject x-user-token)"
    init_body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "console", "version": "1"}}
    }).encode()
    headers = {
        "Authorization": f"Bearer {bearer}",
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    url = f"{AGW_INTERNAL}{path}"
    try:
        req = urllib.request.Request(url, data=init_body, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as r:
            sid = r.headers.get("mcp-session-id") or r.headers.get("Mcp-Session-Id")
            r.read()
    except urllib.error.HTTPError as e:
        return None, f"init HTTP {e.code}"
    except Exception as e:
        return None, f"init error: {e}"
    if not sid:
        return None, "no session id"
    list_body = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}).encode()
    headers["Mcp-Session-Id"] = sid
    try:
        req = urllib.request.Request(url, data=list_body, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as r:
            body = r.read().decode()
    except Exception as e:
        return None, f"tools/list error: {e}"
    for line in body.split("\n"):
        line = line.strip()
        if line.startswith("data:"):
            try:
                obj = json.loads(line[5:].strip())
                return [t["name"] for t in obj.get("result", {}).get("tools", [])], None
            except Exception:
                continue
    return None, "no data: line in SSE response"


def render_page(claims, tools, tools_err, path_tried):
    user = (claims or {}).get("preferred_username") or (claims or {}).get("email") or "(no user)"
    email = (claims or {}).get("email", "")
    aud = (claims or {}).get("aud", "")
    azp = (claims or {}).get("azp", "")
    issuer = (claims or {}).get("iss", "")
    groups = (claims or {}).get("groups", []) or (claims or {}).get("realm_access", {}).get("roles", [])
    team = (claims or {}).get("team", "(none)")
    exp = (claims or {}).get("exp", "")
    sub = (claims or {}).get("sub", "")

    if isinstance(aud, list):
        aud = ", ".join(aud)
    if isinstance(groups, list):
        groups = ", ".join(groups) if groups else "(none)"

    tools_html = ""
    if tools is not None:
        for t in tools:
            tools_html += f'<div class="tool">✓ <span class="mono">{t}</span></div>'
        if not tools:
            tools_html = '<div class="tool muted">(no tools returned)</div>'
    else:
        tools_html = f'<div class="tool err">✗ {tools_err}</div>'

    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<title>AI Agent Console — Your Session</title>
<link href="https://fonts.googleapis.com/css2?family=Figtree:wght@400;600;700&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
:root {{ --bg:#151927; --card:#1E2035; --border:rgba(92,97,120,0.25); --purple:#8023C3; --purple-l:#CC85FF; --blue:#20B7F3; --green:#1FEEB3; --orange:#FFA785; --text:#fff; --sub:#9DA1BD; --body:#B5B8CD; --muted:#5C6178; }}
* {{ box-sizing: border-box; margin:0; padding:0; }}
body {{ background: var(--bg); color: var(--text); font-family: 'Figtree', sans-serif; padding: 2.5rem 2rem; min-height: 100vh; }}
h1 {{ font-size: 1.9rem; margin-bottom: 0.4rem; }} h1 span {{ color: var(--purple-l); }}
.sub {{ font-family: 'DM Mono', monospace; color: var(--sub); margin-bottom: 2rem; font-size: 0.92rem; }}
.grid {{ display: grid; grid-template-columns: 1.1fr 1fr; gap: 1.5rem; max-width: 1300px; }}
.card {{ background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 1.3rem 1.5rem; }}
.card h2 {{ font-size: 1rem; font-weight: 600; margin-bottom: 0.9rem; color: var(--text); display: flex; align-items: center; gap: 0.5rem; }}
.card h2 .badge {{ font-family: 'DM Mono', monospace; font-size: 0.65rem; background: rgba(128,35,195,0.18); color: var(--purple-l); padding: 0.15rem 0.55rem; border-radius: 4px; font-weight: 400; }}
.row {{ display: grid; grid-template-columns: 110px 1fr; gap: 0.5rem; padding: 0.4rem 0; border-bottom: 1px dashed rgba(92,97,120,0.15); font-family: 'DM Mono', monospace; font-size: 0.82rem; }}
.row:last-child {{ border-bottom: none; }}
.row .k {{ color: var(--muted); }}
.row .v {{ color: var(--body); word-break: break-all; }}
.row .v.hi {{ color: var(--green); }}
.tool {{ font-family: 'DM Mono', monospace; font-size: 0.85rem; color: var(--body); padding: 0.32rem 0; display: flex; align-items: center; gap: 0.5rem; }}
.tool span.mono {{ color: var(--purple-l); }}
.tool.err {{ color: var(--orange); }}
.tool.muted {{ color: var(--muted); }}
.linkgrid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 0.6rem; margin-top: 1rem; }}
.linkgrid a {{ background: rgba(21,25,39,0.7); border: 1px solid var(--border); border-radius: 8px; padding: 0.7rem 0.8rem; text-decoration: none; color: var(--text); transition: border-color 0.15s; display: block; }}
.linkgrid a:hover {{ border-color: var(--purple); }}
.linkgrid a .name {{ font-weight: 600; font-size: 0.85rem; }}
.linkgrid a .port {{ font-family: 'DM Mono', monospace; font-size: 0.7rem; color: var(--purple-l); margin-top: 0.2rem; }}
footer {{ color: var(--muted); font-size: 0.78rem; font-family: 'DM Mono', monospace; margin-top: 2rem; max-width: 900px; line-height: 1.6; }}
.mono {{ font-family: 'DM Mono', monospace; }}
</style>
</head><body>
<h1>You are logged in as <span>{user}</span></h1>
<p class="sub">Everything you see below is enforced by the gateway based on your identity.</p>

<div class="grid">
  <div class="card">
    <h2>🔑 Your session <span class="badge">x-user-token (JWT)</span></h2>
    <div class="row"><span class="k">username</span><span class="v hi">{user}</span></div>
    <div class="row"><span class="k">email</span><span class="v">{email}</span></div>
    <div class="row"><span class="k">team</span><span class="v">{team}</span></div>
    <div class="row"><span class="k">groups</span><span class="v">{groups}</span></div>
    <div class="row"><span class="k">aud</span><span class="v">{aud}</span></div>
    <div class="row"><span class="k">azp</span><span class="v">{azp}</span></div>
    <div class="row"><span class="k">iss</span><span class="v">{issuer}</span></div>
    <div class="row"><span class="k">sub</span><span class="v">{sub}</span></div>
    <div class="row"><span class="k">exp</span><span class="v">{exp}</span></div>
  </div>

  <div class="card">
    <h2>🛠 Tools you can call <span class="badge">{path_tried} · live tools/list</span></h2>
    {tools_html}
  </div>
</div>

<div class="card" style="margin-top: 1.5rem; max-width: 1300px;">
  <h2>🧭 Other platform UIs <span class="badge">port-forwarded</span></h2>
  <div class="linkgrid">
    <a href="http://localhost:4000" target="_blank"><div class="name">🛡️ AgentGateway Enterprise</div><div class="port">localhost:4000</div></a>
    <a href="http://localhost:8090" target="_blank"><div class="name">🌐 Gloo Mesh</div><div class="port">localhost:8090</div></a>
    <a href="http://localhost:6274" target="_blank"><div class="name">🔍 MCP Inspector</div><div class="port">localhost:6274</div></a>
    <a href="http://localhost:8081" target="_blank"><div class="name">🔐 Keycloak Admin</div><div class="port">localhost:8081</div></a>
  </div>
</div>

<footer>
  Log in as a different user (demo / tenant-a-agent / tenant-b-agent) to see how the tool list changes.
  The gateway re-evaluates per-tenant tool allowlists from the JWT — same gateway endpoint, different observable behavior.
</footer>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return  # quiet

    def _bearer(self):
        return self.headers.get("x-user-token", "") or self.headers.get("X-User-Token", "")

    def do_GET(self):
        token = self._bearer()
        claims = decode_jwt(token) if token else None
        # Per-tenant default path: derive from username if available
        path_tried = "/mcp"
        if claims:
            username = claims.get("preferred_username", "") or claims.get("email", "")
            if "tenant-a" in username:
                path_tried = "/mcp/tenant-a"
            elif "tenant-b" in username:
                path_tried = "/mcp/tenant-b"
        tools, tools_err = fetch_tools(token, path_tried)

        if self.path.rstrip("/") in ("", "/console", "/me"):
            html = render_page(claims, tools, tools_err, path_tried)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html.encode())
        elif self.path == "/whoami":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(claims or {}).encode())
        elif self.path == "/healthz":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
        else:
            self.send_response(404); self.end_headers()


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8080), Handler)
    print("visible-identity server listening on :8080", flush=True)
    server.serve_forever()
PY
)

${KC} -n "${AGW_NAMESPACE}" create configmap console-ui \
  --from-literal=server.py="${SERVER_PY}" \
  --dry-run=client -o yaml | ${KC} apply -f -

###############################################################################
# 2. Deployment (Python container) + Service
###############################################################################
log "Deploying console-ui (python http.server)"
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
      - name: server
        image: python:3.12-slim
        command: ["python3", "/srv/server.py"]
        env:
        - name: AGW_INTERNAL
          value: "http://agentgateway-hub.agentgateway-system.svc.cluster.local"
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet: { path: /healthz, port: 8080 }
          initialDelaySeconds: 3
          periodSeconds: 5
        volumeMounts:
        - name: code
          mountPath: /srv
      volumes:
      - name: code
        configMap:
          name: console-ui
          items:
          - key: server.py
            path: server.py
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
    targetPort: 8080
EOF

${KC} -n "${AGW_NAMESPACE}" rollout restart deploy/console-ui 2>/dev/null || true
${KC} -n "${AGW_NAMESPACE}" rollout status deploy/console-ui --timeout=90s

###############################################################################
# 3. AGW backend + HTTPRoute + bind to OIDC policy
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
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: console-backend
      namespace: ${AGW_NAMESPACE}
EOF

log "Adding console-route to oidc-extauth policy targets"
CURRENT=$(${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy oidc-extauth \
  -o jsonpath='{.spec.targetRefs}' 2>/dev/null || echo "")
if echo "${CURRENT}" | grep -q 'console-route'; then
  echo "  Already targets console-route"
else
  ${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy oidc-extauth \
    --type=json \
    -p='[{"op":"add","path":"/spec/targetRefs/-","value":{"group":"gateway.networking.k8s.io","kind":"HTTPRoute","name":"console-route"}}]'
fi

log "Visible-Identity console live"
cat <<EOF

Open in a browser:

  http://${AGW_LB}/console/

After Keycloak login you'll see:
  • Your username, email, JWT claims (aud, groups, team, iss, sub, exp)
  • The MCP tools tools/list filters down to FOR YOU
  • Card links to the four other platform UIs (port-forwarded)

To remove: ./scripts/04e-visible-identity.sh --cleanup
EOF
