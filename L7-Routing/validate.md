# L7 Agent Gateway — Routing & Federation

Validates L7-RT-01 through L7-RT-05 on the Singtel POC clusters.

## Run

```bash
KUBE_CONTEXT=cluster1-singtel KUBE_CONTEXT2=cluster2-singtel ./L7-Routing/validate.sh
```

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| L7-RT-01 | Composite Server / Single URL | `tools/list` against one URL returns a merged schema from all configured backends | None |
| L7-RT-02 | L7 Gateway Federation | JSON-RPC call to `/mcp/remote` routes to cluster2 backend transparently | None |
| L7-RT-03 | Stateful Session Affinity | `Mcp-Session-Id` header is issued on initialize; subsequent requests are pinned to the same replica | None |
| L7-RT-04 | Static Tool Filtering | Tool label selectors in `AgentgatewayBackend` limit the exposed tool list per route | None |
| L7-RT-05 | Legacy Protocol Translation | Gateway auto-detects HTTP+SSE vs Streamable HTTP backends and translates between them | None |

## Prerequisites

| Component | Namespace | Check |
|-----------|-----------|-------|
| `cluster1-singtel` context | — | `kubectl config get-contexts cluster1-singtel` |
| agentgateway-hub service | `agentgateway-system` | `kubectl --context cluster1-singtel -n agentgateway-system get svc agentgateway-hub` |
| `mcp-route-remote` HTTPRoute | `agentgateway-system` | required for L7-RT-02 |
| netshoot pod | `debug` | used for in-cluster curl tests |
| mcp-server-everything | `agentgateway-system` (both clusters) | both must be Running |
