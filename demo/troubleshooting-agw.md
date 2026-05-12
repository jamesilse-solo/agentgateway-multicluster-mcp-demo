# Troubleshooting: AgentGateway returns 5xx errors

When MCP Inspector (or any MCP client) talks to AgentGateway and gets back a `500 Internal Server Error`, it usually surfaces as something like:

> `MCP error -32099: Streamable HTTP error: error Posting to endpoint: ...`

That JSON-RPC error code (`-32099`) is the client wrapping a real HTTP 5xx from upstream. **AgentGateway itself is returning the 500** — not Inspector's internal proxy. The cause is almost always one of four things; this doc walks through diagnosing each.

> **Audience**: someone newer to Kubernetes. Every command is copy-paste; expected outputs are shown. Replace `<CTX>` with your kubectl context name (e.g. `cluster1-singtel`). Find yours with `kubectl config get-contexts`.

---

## Quick glossary

| Term | What it means here |
|------|--------------------|
| **kubectl context** | A named pointer to a specific Kubernetes cluster. `kubectl --context=cluster1-singtel ...` runs the command against that cluster. |
| **pod** | One running container (or group of containers). AGW, ExtAuth, Redis (`ext-cache`) each run as one or more pods. |
| **deployment** | A controller that keeps a desired number of pods running. `deploy/agentgateway-hub` is the AGW data-plane deployment. |
| **access log** | A per-request log line AGW writes for every HTTP request it serves. Includes status code, path, latency, and `response_flags`. |
| **`response_flags`** | A short Envoy code in each access-log line that explains *why* a response failed. The "smoking gun" for 5xx diagnosis. |

---

## Step 0 — Confirm AGW is the one returning the 500

If you can run curl from a host that can reach the AGW LoadBalancer, bypass Inspector entirely and probe the gateway directly:

```bash
# Get the LB hostname:
AGW_LB=$(kubectl --context=<CTX> -n agentgateway-system \
  get gateway agentgateway-hub \
  -o jsonpath='{.status.addresses[0].value}')
echo "AGW: http://${AGW_LB}"

# Probe /mcp with a JWT (replace ${TOKEN} with a valid Bearer):
curl -i http://${AGW_LB}/mcp \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -X POST \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"diag","version":"1"}}}'
```

- **HTTP 200/202**: the gateway is fine — the problem is in the MCP client (Inspector, etc.). Skip to *"Common Inspector gotchas"* at the bottom.
- **HTTP 5xx**: the gateway returned the error. Continue below.

---

## Step 1 — Read the failing access-log line and decode `response_flags`

This single command, run as the request fails, tells you ~80% of what's wrong:

```bash
kubectl --context=<CTX> -n agentgateway-system logs deploy/agentgateway-hub --tail=200 \
  | grep ' 500 '
```

You should see lines that look roughly like (Envoy access-log format):

```
[2026-05-12T03:14:22.123Z] "POST /mcp HTTP/1.1" 500 UAEX 0 - 13ms ...
                                                ↑   ↑
                                             status  response_flags
```

The **`response_flags`** token (here `UAEX`) is the key. Decode using this table — each flag points at a different root cause:

| Flag | Means | Likely cause | Next step |
|------|-------|--------------|-----------|
| `UAEX` | ExtAuth (external authorization) failed | Auth pod crashed, Redis unreachable, or Dex unreachable | **Go to Step 2** |
| `UF` | Upstream connection failure | The MCP backend pod is down or networking is broken | **Go to Step 4** |
| `UH` | No healthy upstream | All backend pods are failing readiness | **Go to Step 4** |
| `UT` | Upstream request timeout | The MCP backend is too slow or hung | **Go to Step 4** |
| `DPE` | Downstream protocol error | Client request shape is malformed | **Go to Step 3** |
| `NR` | No route configured | The path you're hitting has no HTTPRoute | Check `kubectl -n agentgateway-system get httproute` |

If you see *no* lines matching ` 500 `, double-check the `<CTX>` name and that the request you're investigating actually reached this cluster.

---

## Step 2 — ExtAuth failure (`UAEX`)

The 500 came from the gateway's authentication step. Three sub-causes, in decreasing likelihood:

### 2a — `ext-cache` (Redis) is missing or unhealthy

The OIDC session cookie flow stores state in Redis. If Redis isn't running, ExtAuth can't read the session, returns an error, AGW emits 500.

```bash
kubectl --context=<CTX> -n agentgateway-system get pod | grep ext-cache
```

- **Expected (healthy)**: one pod, `STATUS=Running`, `READY=1/1`
  ```
  ext-cache-enterprise-agentgateway-67d75d8b48-k5nt5   1/1   Running   0   3h
  ```
- **Broken — no row at all**: Redis was never deployed. Fix: enable it on the `EnterpriseAgentgatewayParameters`:

  ```bash
  kubectl --context=<CTX> -n agentgateway-system patch \
    enterpriseagentgatewayparameters agentgateway-config \
    --type=merge \
    -p='{"spec":{"sharedExtensions":{"extauth":{"enabled":true},"ratelimiter":{"enabled":true},"extCache":{"enabled":true}}}}'
  ```
- **Broken — `STATUS=CrashLoopBackOff` or `Error`**: look at the pod log:
  ```bash
  kubectl --context=<CTX> -n agentgateway-system logs <ext-cache-pod-name> --tail=50
  ```

### 2b — ExtAuth pod itself is panicking

```bash
kubectl --context=<CTX> -n agentgateway-system get pod | grep ext-auth
# (note the pod name from output)

kubectl --context=<CTX> -n agentgateway-system \
  logs deploy/ext-auth-service-enterprise-agentgateway --tail=100 \
  | grep -iE 'error|panic|denied|timeout|refused'
```

- **Healthy log lines** look mostly like `level":"info"` and "request OK".
- **Bad signs**: `panic`, `connection refused`, `dial tcp`, `JWKS fetch failed`, `Redis dial failed`.

If you see `dial tcp ... :6379` errors, that's confirming Step 2a — ExtAuth can't reach Redis.

If you see `JWKS fetch failed` or anything mentioning `dex.dex.svc.cluster.local`, that's Step 2c.

### 2c — Dex itself is unreachable from ExtAuth

```bash
kubectl --context=<CTX> -n dex get pod
```

- **Expected**: one pod, `STATUS=Running`. If it's missing or crashing, ExtAuth can't fetch JWKS to verify tokens.
- Restart it if needed:
  ```bash
  kubectl --context=<CTX> -n dex rollout restart deployment/dex
  ```

---

## Step 3 — Downstream protocol error (`DPE`)

The gateway rejected the request shape before forwarding. Most often:

1. **Missing required `Accept` header.** MCP Streamable HTTP requires both `application/json` and `text/event-stream`:
   ```
   Accept: application/json, text/event-stream
   ```
2. **Wrong HTTP method** — MCP calls are `POST`, not `GET` or `PUT`.
3. **Body isn't valid JSON-RPC** — Inspector sometimes sends extra `_meta` or `capabilities` fields a strict MCP filter chokes on.

To see the rejected request body, increase data-plane log verbosity temporarily and reproduce the request:

```bash
kubectl --context=<CTX> -n agentgateway-system logs deploy/agentgateway-hub --tail=500 \
  | grep -B2 -A2 ' 500 '
```

Lines surrounding the 500 usually include the request method, path, and any parse-error message.

---

## Step 4 — Upstream issue (`UF`, `UH`, `UT`)

The auth step passed; AGW tried to forward to the backend MCP server and that failed.

```bash
# Which backend was the route pointing at? Find the HTTPRoute and trace it:
kubectl --context=<CTX> -n agentgateway-system get httproute
# Look at the route for the path you hit:
kubectl --context=<CTX> -n agentgateway-system get httproute <route-name> -o yaml

# Look at the AgentgatewayBackend named in the route:
kubectl --context=<CTX> -n agentgateway-system get agentgatewaybackend <backend-name> -o yaml
```

The `static.host` + `static.port` in the backend tells you which Service or external host AGW is trying to reach. Then:

```bash
# If the backend is in-cluster (e.g. a Service in agentgateway-system):
kubectl --context=<CTX> -n <ns> get svc,pod | grep <backend-host>

# If the backend is external (e.g. search.solo.io):
# From a pod in the cluster, can it reach the upstream?
kubectl --context=<CTX> -n debug exec deploy/netshoot -- \
  curl -v --max-time 5 https://<upstream-host>/
```

`UF` typically means the connection itself didn't establish (firewall, wrong port, upstream down). `UT` means it connected but the response was too slow.

---

## What to send back when asking for help

If after Steps 0–4 you still don't know the cause, paste the following into your support thread or issue:

```bash
# 1) The actual 500 access log line(s) — most important
kubectl --context=<CTX> -n agentgateway-system logs deploy/agentgateway-hub --tail=200 \
  | grep ' 500 '

# 2) ExtAuth pod log tail
kubectl --context=<CTX> -n agentgateway-system \
  logs deploy/ext-auth-service-enterprise-agentgateway --tail=100

# 3) All pods in agentgateway-system with their status
kubectl --context=<CTX> -n agentgateway-system get pod

# 4) The route + backend + policy for the path that's failing (e.g. /mcp/search)
kubectl --context=<CTX> -n agentgateway-system get \
  httproute,agentgatewaybackend,agentgatewaypolicy

# 5) AGW versions
kubectl --context=<CTX> -n agentgateway-system get deploy agentgateway-hub \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

The combination of access-log `response_flags`, ExtAuth log, and pod status is enough for someone on the Solo SE side to pinpoint the cause without further round-trips.

---

## Common Inspector gotchas (if curl works fine but Inspector still errors)

If Step 0's `curl` returned a clean 200 but MCP Inspector still fails, the gateway is innocent and the problem is in the client:

| Inspector behaviour | Fix |
|---|---|
| Using the "OAuth" tab instead of "Custom Headers" | Switch to **Authentication → Custom Headers**; add a header named `Authorization` with value `Bearer <your-token>`. Do not use the OAuth tab — see `mcp-inspector.md` section 6. |
| Bearer token expired between login and click | Re-acquire the token in the same shell that's running `npx @modelcontextprotocol/inspector`; tokens default to short lifetimes. |
| Browser cached an old auth state | Click "Disconnect" in the Inspector UI, refresh the browser tab, paste the token again, reconnect. |

---

## Related docs

- [`mcp-inspector.md`](mcp-inspector.md) — how to point MCP Inspector at the AGW Hub (jumphost and laptop scenarios)
- [`adding-mcp-servers.md`](adding-mcp-servers.md) — how routes/backends/policies are wired up; useful when Step 4 leads you to a misconfigured backend
- [`send-traffic.sh`](send-traffic.sh) — a known-good reference flow; if this script works against your gateway, the core path is healthy
