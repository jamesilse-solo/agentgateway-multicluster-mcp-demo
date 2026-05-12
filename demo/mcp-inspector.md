# Using MCP Inspector with the AgentGateway Hub

This walks through pointing the [Model Context Protocol Inspector](https://github.com/modelcontextprotocol/inspector) at the AgentGateway Hub on cluster1. Useful for:

- Interactively browsing the tools an MCP server exposes
- Testing auth (Bearer JWT) and rate limits without writing client code
- Verifying that the gateway's tool-RBAC policies filter `tools/list` correctly
- Running against `/mcp`, `/mcp/remote`, `/mcp/search`, and `/mcp/registry` to compare local, federated, external, and registry-backed MCP behaviour

Two scenarios are covered:

- **Scenario A — Jumphost** (sections 1–4): a managed jumphost with `kubectl` + AWS auth, where `./demo/portforward.sh` is already running.
- **Scenario B — Laptop hitting the AGW public IP directly** (section 5): the customer's laptop running Inspector locally and connecting straight to the gateway's external LoadBalancer. Includes the **"my JWT issuer is `dex.dex.svc.cluster.local` — does this break Bearer auth?"** debugging path.

> **Common assumption for both scenarios**: `./demo/portforward.sh` is running somewhere reachable from where you run Inspector — it gives you `localhost:5556` for Dex token acquisition. The AGW Hub `/mcp` endpoint is a public cloud `LoadBalancer` and does **not** need to be port-forwarded.

---

## Prerequisites

| Tool | Why |
|------|-----|
| Node.js ≥ 18 + `npx` | MCP Inspector ships as an npm package; `npx` invokes it without a global install |
| `kubectl` (already configured for `cluster1-singtel`) | port-forward Dex on 5556 (handled by `portforward.sh`) |
| `curl`, `jq` | Acquire and decode the Bearer JWT |
| The AGW Hub LB hostname | Printed by `portforward.sh` under the **AgentGateway MCP Endpoints** section |

The AGW Hub LB is publicly reachable on the internet (it's a cloud `LoadBalancer` Service). The jumphost connects to it directly — no need to port-forward `/mcp` paths.

---

## 1. Capture the AGW Hub LB hostname

The `portforward.sh` output's section 5 prints it, but you can re-resolve it on the fly:

```bash
export AGW_LB=$(kubectl --context cluster1-singtel -n agentgateway-system \
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

This is for the case where a customer (or you) runs MCP Inspector **directly on a laptop** and connects to the AgentGateway's public LoadBalancer hostname/IP — no jumphost involved as a hop for the MCP traffic itself. The token still has to come from somewhere; either the laptop has `kubectl` access or there's an `ssh -L` tunnel through a jumphost that does.

> **TL;DR**: use the **same manual Bearer flow** as the jumphost scenario. **Do not** use Inspector's "OAuth" / "Auto Connect" tab — see section 6 for why.

### 5.1 Pre-reqs on the laptop

- AWS SSO logged in (`aws sso login`) and `kubectl` configured for `cluster1-singtel`, **OR** an `ssh -L 5556:localhost:5556 your-user@jumphost` tunnel up against a jumphost where `./demo/portforward.sh` is running.
- Node ≥ 18 (`node --version`) — required by `npx`.

### 5.2 Acquire a JWT on the laptop

Same flow as `demo/send-traffic.sh` — port-forward Dex locally (or use the ssh tunnel), then password-grant:

```bash
# Skip the next line if you already have an ssh -L 5556 tunnel up to a jumphost
kubectl --context=cluster1-singtel -n dex port-forward svc/dex 5556:5556 &

export TOKEN=$(curl -s -X POST http://localhost:5556/dex/token \
  -d 'grant_type=password' \
  -d 'username=demo@example.com' \
  -d 'password=demo-pass' \
  -d 'client_id=agw-client' \
  -d 'client_secret=agw-client-secret' \
  -d 'scope=openid email profile' \
  | jq -r '.id_token')

# Sanity-check the token has an exp far enough in the future:
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.exp, .iss, .aud'
```

The `iss` in the token will be `http://dex.dex.svc.cluster.local:5556/dex/`. **That's fine.** Section 6 explains why the laptop never has to reach that URL.

### 5.3 Resolve the AGW Hub LB

```bash
export AGW_LB=$(kubectl --context=cluster1-singtel -n agentgateway-system \
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

> **Do NOT use the "OAuth" tab.** Inspector's OAuth mode does RFC 9728 / 8414 discovery against the issuer URL embedded in the token — and that URL (`dex.dex.svc.cluster.local`) only resolves inside the cluster. With Custom Headers Bearer, Inspector simply attaches your token to every request; the gateway's ExtAuth validates it server-side. See section 6.

---

## 6. The cluster-FQDN issuer question

Q: *"The JWT's `iss` is `http://dex.dex.svc.cluster.local:5556/dex/` — an in-cluster hostname I can't reach from my laptop. Doesn't that break things?"*

It depends on what's doing the validation:

- **Manual Bearer flow** (what sections 4 and 5 use): **not affected.** The JWT's `iss` claim is just a string the gateway's ExtAuth uses to look up JWKS — via in-cluster DNS, from inside the cluster, where the FQDN does resolve. Your laptop never reaches the issuer URL. It simply presents the token; the gateway accepts or rejects it.
- **Automatic OAuth discovery / authorization-code flow** (what Inspector's "OAuth" tab tries to do): **would fail from a laptop.** Inspector would try to fetch `http://dex.dex.svc.cluster.local:5556/dex/.well-known/openid-configuration` — a hostname only resolvable inside the cluster — and time out. Additionally, this demo's gateway does not publish OAuth metadata (no `resourceMetadata` configured, no `/.well-known/oauth-protected-resource` route), so auto-discovery can't find anything even if the laptop could reach Dex. There's no useful path here for the laptop scenario — stick with Custom Headers Bearer.
- **Production-grade fix** (out of scope for this doc — brief pointer): expose `/dex` via a new HTTPRoute attached to the existing `dex-backend` AgentgatewayBackend (see `demo/adding-mcp-servers.md` for the pattern), change Dex's configured `issuer` to `http://<agw-lb>/dex`, update ExtAuth's `AuthConfig.oauth2.oidcAuthorizationCode.issuerUrl` to match, and optionally add `resourceMetadata` on an `AgentgatewayPolicy` so MCP clients can do auto-discovery. After that, both flows work for external clients.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `HTTP 302 Found` redirect to `/dex/auth` | Missing or expired Bearer token | Re-run section 2 (or 5.2) to refresh `$TOKEN` |
| `HTTP 401 Unauthorized` | Token tampered or wrong audience | Decode the token and check `aud`/`iss` match the gateway's `AuthConfig`; re-acquire |
| `HTTP 404 Not Found` | Wrong path; the route doesn't exist on the gateway | `kubectl --context cluster1-singtel -n agentgateway-system get httproute` to list registered paths |
| Inspector hangs at "Connecting…" | Network egress is blocked, OR the AGW LB isn't reachable on port 80 | `curl -v http://${AGW_LB}/mcp` — should return at least an HTTP response. If not, check security groups / corporate proxy |
| `tools/list` returns fewer tools than the upstream MCP server | Working as designed — `AgentgatewayPolicy.mcp.authorization` is filtering. See `demo/adding-mcp-servers.md` for the policy mechanism |
| `connection refused` to `localhost:5556` | `portforward.sh` not running or Dex port-forward died | Start a new terminal: `./demo/portforward.sh` |
| Inspector's "OAuth" tab redirects to `dex.dex.svc.cluster.local` and hangs | Inspector is trying automatic OIDC discovery against an in-cluster issuer | Switch to **Custom Headers Bearer** (section 5.4); this demo's gateway doesn't publish OAuth discovery metadata. See section 6 |
| `curl` with Bearer works but Inspector returns "auth failed" | Inspector is using the OAuth tab despite the Bearer being set | In the Inspector UI use the **Custom Headers** input, not the OAuth tab; clear cached auth state and reconnect |
| Inspector shows `500 Internal Server Error` while trying to connect | Almost never AgentGateway itself — it returns 302 (no auth) or 404 (no matching route), not 500. The 500 is usually Inspector's local **proxy server** (port 6277) failing to follow an OAuth redirect to an unreachable issuer host, OR a downstream MCP server crashing on a malformed payload. | (1) Confirm the 5xx isn't AGW: `curl -i http://${AGW_LB}/mcp -H "Authorization: Bearer ${TOKEN}"` — should be 200/204/202. (2) If that's clean, check Inspector's proxy log in the terminal where you ran `npx`. (3) Check the AGW data plane log for any 5xx: `kubectl --context=cluster1-singtel -n agentgateway-system logs deploy/agentgateway-hub --tail=50 \| grep -iE "5[0-9]{2}\|error"` |
| JWT works from jumphost, fails from laptop with the **same** token | Token pasted with extra whitespace, or quietly expired between hops | Re-acquire on the laptop in the same shell you'll run Inspector from; verify with `echo $TOKEN \| cut -d. -f2 \| base64 -d \| jq .exp` |

---

## Related docs

- [`demo/portforward.sh`](portforward.sh) — sets up the local port-forwards (Dex on 5556, AGW UI on 4000, Registry on 8080, Gloo Mesh UI on 8090)
- [`demo/send-traffic.sh`](send-traffic.sh) — what Inspector does, in shell form: token acquisition + initialize + tools/list + tools/call
- [`demo/adding-mcp-servers.md`](adding-mcp-servers.md) — how the routes you're inspecting were configured; explains AgentgatewayBackend + HTTPRoute + AgentgatewayPolicy
- [`POC-Success-Criteria-v2/Phase5-Identity-and-Access/`](../POC-Success-Criteria-v2/Phase5-Identity-and-Access/) — AUTH-01 / AUTH-03 validation tests cover the same flow programmatically
