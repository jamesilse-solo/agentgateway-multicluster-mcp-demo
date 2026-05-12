# Using MCP Inspector with the AgentGateway Hub

This walks through pointing the [Model Context Protocol Inspector](https://github.com/modelcontextprotocol/inspector) at the AgentGateway Hub on cluster1. Useful for:

- Interactively browsing the tools an MCP server exposes
- Testing auth (Bearer JWT) and rate limits without writing client code
- Verifying that the gateway's tool-RBAC policies filter `tools/list` correctly
- Running against `/mcp`, `/mcp/remote`, `/mcp/search`, and `/mcp/registry` to compare local, federated, external, and registry-backed MCP behaviour

Two scenarios are covered:

- **Scenario A — Jumphost** (sections 1–4): a managed jumphost with `kubectl` + AWS auth, where `./demo/portforward.sh` is already running.
- **Scenario B — Laptop hitting the AGW public IP directly** (section 5): the customer's laptop running Inspector locally and connecting straight to the gateway's external LoadBalancer. Both **Custom Headers Bearer** and Inspector's **OAuth tab** work from a laptop because `/dex/*` is exposed through the AGW LB (see section 6).

> **Common assumption**: the AGW Hub `/mcp` endpoint is a public cloud `LoadBalancer` and does **not** need port-forwarding. Dex (`/dex/*`) is also exposed through the same LB, so token acquisition from a laptop no longer requires a port-forward. `./demo/portforward.sh` is still useful for the jumphost workflow and for the supporting UIs (AGW UI on 4000, Registry on 8080, Gloo Mesh UI on 8090).

---

## Prerequisites

| Tool | Why |
|------|-----|
| Node.js ≥ 18 + `npx` | MCP Inspector ships as an npm package; `npx` invokes it without a global install |
| `kubectl` (already configured for `cluster1`) | port-forward Dex on 5556 (handled by `portforward.sh`) |
| `curl`, `jq` | Acquire and decode the Bearer JWT |
| The AGW Hub LB hostname | Printed by `portforward.sh` under the **AgentGateway MCP Endpoints** section |

The AGW Hub LB is publicly reachable on the internet (it's a cloud `LoadBalancer` Service). The jumphost connects to it directly — no need to port-forward `/mcp` paths.

---

## 1. Capture the AGW Hub LB hostname

The `portforward.sh` output's section 5 prints it, but you can re-resolve it on the fly:

```bash
export AGW_LB=$(kubectl --context cluster1 -n agentgateway-system \
  get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

echo "AGW Hub: http://${AGW_LB}"
```

Available paths (the routes attached to the hub):

| Path | Backend | Notes |
|------|---------|-------|
| `/mcp` | `mcp-server-everything` (local on cluster1) | Reference MCP server with 10 tools |
| `/mcp/remote` | `mcp-server-everything` on cluster2 via HBONE | Same server, federated cross-cluster |
| `/mcp/search` | `search.solo.io` (public, HTTPS) | External MCP server with `mcp.authorization` allowlist (`mcp.tool.name == "search"`) |
| `/mcp/registry` | AgentRegistry's MCP catalog | `tools/list` returns the catalog of registered servers |

All four paths require a valid `Authorization: Bearer <JWT>` header.

---

## 2. Acquire a JWT from Dex

`portforward.sh` is already forwarding Dex on `localhost:5556`. Use the demo password grant:

```bash
export TOKEN=$(curl -s -X POST http://localhost:5556/dex/token \
  -d 'grant_type=password' \
  -d 'username=demo@example.com' \
  -d 'password=demo-pass' \
  -d 'client_id=agw-client' \
  -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' \
  | jq -r '.id_token')

# Sanity check — should print a JSON object with iss, aud, exp:
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

Tokens expire (default ~24h for Dex). Re-run this block if the inspector starts returning 302 or 401.

---

## 3. Launch MCP Inspector

Two modes. **UI mode** is what most people use; **CLI mode** is useful on a headless jumphost or for scripting.

### 3a. UI mode (recommended)

MCP Inspector spawns a local proxy + browser UI. From the jumphost:

```bash
npx @modelcontextprotocol/inspector
```

It opens two ports on the jumphost:

- `6277` — proxy / session server (HTTP API and the WebSocket bridge to upstream MCP servers)
- `6274` — web UI

If the jumphost has a desktop, point a browser at `http://localhost:6274`. If it doesn't (most common for a managed jumphost), forward those ports back to your laptop via `ssh -L`:

```bash
# On your laptop, in a separate terminal:
ssh -L 6274:localhost:6274 -L 6277:localhost:6277 your-user@jumphost
# Then open http://localhost:6274 in your laptop's browser
```

In the Inspector UI:

| Field | Value |
|-------|-------|
| Transport Type | **Streamable HTTP** |
| URL | `http://<AGW_LB>/mcp` (substitute your LB hostname; or any of the other paths above) |
| Authentication / Custom Headers | Add a header named `Authorization` with value `Bearer <paste TOKEN here>` |

Click **Connect**, then **List Tools** in the left sidebar. The right pane shows the JSON-RPC request and response.

### 3b. CLI mode (headless / scripted)

For a quick `tools/list` against the AGW Hub without launching a UI:

```bash
npx @modelcontextprotocol/inspector \
  --cli \
  --transport http \
  --server-url "http://${AGW_LB}/mcp" \
  --header "Authorization: Bearer ${TOKEN}" \
  --method tools/list
```

To call a specific tool:

```bash
npx @modelcontextprotocol/inspector \
  --cli \
  --transport http \
  --server-url "http://${AGW_LB}/mcp" \
  --header "Authorization: Bearer ${TOKEN}" \
  --method tools/call \
  --tool-name echo \
  --tool-arg message="Hello from MCP Inspector"
```

> CLI flag names track the upstream package. Run `npx @modelcontextprotocol/inspector --cli --help` if your version differs.

---

## 4. Worked examples — what to verify

### Example 1 — local MCP via `/mcp`

```bash
# Through the gateway with the JWT — expect 10 tools
curl -s -i -X POST "http://${AGW_LB}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"jumphost","version":"1"}}}' \
  | head -10
```

Capture the `Mcp-Session-Id` header, then send `tools/list` with both that header and the `Authorization`. Compare to what Inspector shows in the UI.

### Example 2 — federated `/mcp/remote`

Identical to Example 1 with the URL changed. The response comes from cluster2's MCP server via the HBONE tunnel, but the agent has no way to tell.

### Example 3 — external `/mcp/search` (with tool-RBAC)

```bash
npx @modelcontextprotocol/inspector \
  --cli --transport http \
  --server-url "http://${AGW_LB}/mcp/search" \
  --header "Authorization: Bearer ${TOKEN}" \
  --method tools/list
```

The upstream `search.solo.io` exposes 3 tools (`search`, `get_chunks`, `get_full_page`), but the gateway has an `AgentgatewayPolicy` with `mcp.authorization` allowing only `search`. Inspector's `tools/list` will show exactly one tool. Try calling a non-allowed tool to confirm the gateway rejects it:

```bash
npx @modelcontextprotocol/inspector \
  --cli --transport http \
  --server-url "http://${AGW_LB}/mcp/search" \
  --header "Authorization: Bearer ${TOKEN}" \
  --method tools/call \
  --tool-name get_chunks
# → "Unknown tool: get_chunks"  (rejected at the gateway; never reaches the upstream)
```

### Example 4 — registry `/mcp/registry`

The AgentRegistry exposes its catalog as an MCP server. `tools/list` returns synthetic tools representing discovery operations on the registry itself.

---

## 5. Scenario B — Laptop hitting the AGW public IP/hostname

This is for the case where a customer (or you) runs MCP Inspector **directly on a laptop** and connects to the AgentGateway's public LoadBalancer hostname/IP — no jumphost involved as a hop for the MCP traffic itself.

Two paths both work from a laptop:

- **Custom Headers Bearer** (sections 5.2–5.4) — fast, always reliable, doesn't depend on Inspector's OAuth implementation.
- **Inspector's OAuth tab** — also works because `/dex/*` is exposed through the AGW LB (see section 6). The token, login redirect, and callback all resolve from the laptop with no port-forward or VPN.

### 5.1 Pre-reqs on the laptop

- Node ≥ 18 (`node --version`) — required by `npx @modelcontextprotocol/inspector`.
- Network egress to the AGW LB hostname on port 80 (corporate proxies / split-tunnel VPNs can block this — `curl -I http://<agw-lb>/dex/.well-known/openid-configuration` is the quickest pre-flight).

`kubectl` access is **not required** for Inspector itself — the laptop talks to the gateway over HTTP only.

### 5.2 Acquire a JWT on the laptop

Hit the Dex `/token` endpoint **directly through the AGW LB** — no port-forward needed:

```bash
export AGW_LB=$(kubectl --context=cluster1 -n agentgateway-system \
  get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
# Or, if you don't have kubectl access, ask the cluster admin for the LB hostname.

export TOKEN=$(curl -s -X POST "http://${AGW_LB}/dex/token" \
  -d 'grant_type=password' \
  -d 'username=demo@example.com' \
  -d 'password=demo-pass' \
  -d 'client_id=agw-client' \
  -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' \
  | jq -r '.id_token')

# Sanity-check exp/iss/aud — JWT segments use URL-safe base64 without padding,
# so the naive `base64 -d` doesn't work. Use python or pad + tr:
python3 -c "import sys,base64,json; s='$TOKEN'.split('.')[1]; s+='='*(-len(s)%4); d=json.loads(base64.urlsafe_b64decode(s)); print('exp',d['exp'],'iss',d['iss'],'aud',d['aud'])"
```

The `iss` claim will be `http://<agw-lb>/dex` — the same URL the laptop can reach. That's what makes the OAuth tab work too.

### 5.3 Resolve the AGW Hub LB

```bash
export AGW_LB=$(kubectl --context=cluster1 -n agentgateway-system \
  get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')

# By raw IP also works — none of the HTTPRoutes pin a Host header:
nslookup "$AGW_LB" | awk '/^Address: / {print $2; exit}'
```

### 5.4 Launch Inspector on the laptop

```bash
npx @modelcontextprotocol/inspector
# Opens browser at http://localhost:6274
```

In the connection panel:

| Field | Value |
|-------|-------|
| Transport Type | **Streamable HTTP** |
| URL | `http://${AGW_LB}/mcp` (substitute the LB hostname; or `http://<resolved-ip>/mcp` works too) |
| **Authentication** | Open **Authentication → Custom Headers**. Add a header named `Authorization` with value `Bearer <paste TOKEN here>`. |

Click **Connect**, then **List Tools**.

> Inspector's **"OAuth" tab also works** in this demo because `/dex/*` is routed through the AGW LB and the JWT issuer matches that public URL. If you'd rather Inspector handle the full OAuth round-trip (browser-based login, callback, token exchange), select **OAuth** instead of Custom Headers and click Connect — you'll be redirected to the Dex login page, sign in as `demo@example.com / demo-pass`, and Inspector will complete the rest. See section 6 for the architecture that makes this work.

---

## 6. How Dex is reachable from outside the cluster

Q: *"What changed so the OAuth flow works from a laptop?"*

The demo's `05-extauth.sh` script puts three pieces in place:

1. **`dex-route` HTTPRoute** — exposes `/dex/*` on the AGW Hub LoadBalancer, backed by the in-cluster Dex Service via `dex-backend`. Path is left unauthenticated (the ExtAuth policy is scoped to specific MCP/UI routes, not the whole Gateway), otherwise the login redirect would itself need a valid session.
2. **Dex `issuer` patched** to `http://<agw-lb>/dex` — every JWT Dex issues now has an `iss` claim that's resolvable from any external client.
3. **ExtAuth `AuthConfig.issuerUrl`** matches Dex's `issuer` — JWKS fetches happen inside the cluster (so cluster-internal DNS still works for that), but the validation comparison against the token's `iss` claim succeeds because both sides use the public URL.

Consequences:

- **Custom Headers Bearer** (sections 4 and 5.4): unchanged — still the simplest path.
- **OAuth tab in Inspector**: works because Inspector's automatic discovery (`/.well-known/openid-configuration`), the user-agent login redirect (`/dex/auth/...`), and the token exchange (`/dex/token`) are all reachable through the LB.
- **`resourceMetadata` / RFC 9728 protected-resource discovery**: still not configured. MCP clients that strictly enforce RFC 9728 won't find an `oauth-protected-resource` document on `/mcp` — but Inspector's OAuth tab falls back to the `WWW-Authenticate` challenge model and works fine.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `HTTP 302 Found` redirect to `/dex/auth` | Missing or expired Bearer token | Re-run section 2 (or 5.2) to refresh `$TOKEN` |
| `HTTP 401 Unauthorized` | Token tampered or wrong audience | Decode the token and check `aud`/`iss` match the gateway's `AuthConfig`; re-acquire |
| `HTTP 404 Not Found` | Wrong path; the route doesn't exist on the gateway | `kubectl --context cluster1 -n agentgateway-system get httproute` to list registered paths |
| Inspector hangs at "Connecting…" | Network egress is blocked, OR the AGW LB isn't reachable on port 80 | `curl -v http://${AGW_LB}/mcp` — should return at least an HTTP response. If not, check security groups / corporate proxy |
| `tools/list` returns fewer tools than the upstream MCP server | Working as designed — `AgentgatewayPolicy.mcp.authorization` is filtering. See `demo/adding-mcp-servers.md` for the policy mechanism |
| `connection refused` to `localhost:5556` | `portforward.sh` not running or Dex port-forward died (only relevant for the jumphost scenario; laptops no longer need to port-forward Dex — section 5.2 uses the LB directly) | Start a new terminal: `./demo/portforward.sh` |
| Inspector connects but immediately shows `Unexpected content type: text/html; charset=utf-8` | The URL field is missing `/mcp` — Inspector hit the gateway root, which returned an HTML 404 / Dex login page | Set URL to `http://<agw-lb>/mcp` (with the path), not `http://<agw-lb>` |
| Inspector's "OAuth" tab fails with `Unregistered redirect_uri` | The current AGW LB hostname isn't in Dex's `staticClients[*].redirectURIs` (happens after a fresh LB provisioning when `AGW_LB` wasn't set at `03-dex.sh` time) | Re-run `05-extauth.sh` — it patches the Dex configmap with the current LB. Or manually update the configmap and `rollout restart deployment/dex -n dex` |
| Inspector shows `500 Internal Server Error` while trying to connect | Almost never AgentGateway itself — it returns 302 (no auth) or 404 (no matching route), not 500. The 500 is usually Inspector's local **proxy server** (port 6277) failing to follow a redirect, OR a downstream MCP server crashing on a malformed payload. | (1) Confirm the 5xx isn't AGW: `curl -i http://${AGW_LB}/mcp -H "Authorization: Bearer ${TOKEN}"` — should be 200/204/202. (2) If clean, check Inspector's proxy log in the terminal where you ran `npx`. (3) See [`troubleshooting-agw.md`](troubleshooting-agw.md) for the response-flags-based AGW 5xx walkthrough |
| JWT works in `curl` but Inspector returns `auth failed` | The `Bearer ` prefix was double-prepended (Inspector has both a "Bearer Token" field that prepends, and a Custom Headers field where you'd add it manually — using both gives `Bearer Bearer eyJ...`) | Use **one** of the two: either the Bearer Token field with just the raw token, or Custom Headers with the full `Bearer eyJ...` string |
| JWT works from jumphost, fails from laptop with the **same** token | Token pasted with extra whitespace, or quietly expired between hops | Re-acquire on the laptop in the same shell you'll run Inspector from; verify with `python3 -c "import sys,base64,json; s='$TOKEN'.split('.')[1]; s+='='*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s))['exp'])"` |

---

## Related docs

- [`demo/portforward.sh`](portforward.sh) — sets up the local port-forwards (Dex on 5556, AGW UI on 4000, Registry on 8080, Gloo Mesh UI on 8090)
- [`demo/send-traffic.sh`](send-traffic.sh) — what Inspector does, in shell form: token acquisition + initialize + tools/list + tools/call
- [`demo/adding-mcp-servers.md`](adding-mcp-servers.md) — how the routes you're inspecting were configured; explains AgentgatewayBackend + HTTPRoute + AgentgatewayPolicy
- [`POC-Success-Criteria-v2/Phase5-Identity-and-Access/`](../POC-Success-Criteria-v2/Phase5-Identity-and-Access/) — AUTH-01 / AUTH-03 validation tests cover the same flow programmatically
