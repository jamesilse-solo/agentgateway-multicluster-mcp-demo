# Phase 3 — Federated MCP Gateway Mesh

> **Kubernetes Gateway API v1.4.0 (standard channel)** required on **both** clusters. The federation routes are `HTTPRoute` resources (`gateway.networking.k8s.io/v1`) targeting `AgentgatewayBackend` (`agentgateway.dev/v1alpha1`) backends. The east-west tunnel relies on Istio ambient mesh (HBONE on ports 15008 + 15012). See [`../README.md`](../README.md#kubernetes-gateway-api-requirements) for the full version + CRD matrix.

> Validates **FED-01, FED-02, FED-03** — the cross-cluster routing properties that turn a collection of independent MCP Gateways into a single, coherent fabric. This is the phase the customer's Enterprise Architects care about most: it answers *"how do agents in one environment reach tools in another, and what does it take to add a new environment?"*

The architecture model is a **distributed MCP Gateway mesh**, not hub-and-spoke:

- Every environment runs its own MCP Gateway (reai, Networks, on-prem).
- Gateways are joined by HBONE tunnels (ports 15008 and 15012). No additional firewall rules.
- Agents call their **local** gateway. The gateway decides whether to serve locally or forward to a peer gateway over HBONE.
- Adding a third environment is the same work as the second.

## What this phase proves

1. **Federation is transparent.** An agent calls a single URL. Whether the tool lives locally or in a peer cluster is invisible. (FED-01, FED-02)
2. **Federation is symmetric.** Every gateway can reach every other gateway, in both directions. There is no privileged "hub". (FED-02)
3. **Multiple backends look like one server.** A composite MCP Gateway route can aggregate three real MCP servers (mix of local + remote) into one logical server with a unified `tools/list`. (FED-03)

## Tests in this phase

| ID | Requirement | What success proves | Net cluster change |
|----|-------------|---------------------|--------------------|
| FED-01 | Cross-Environment Federation (cluster1 → cluster2) | Agent on cluster1 calls `/mcp/remote`; the gateway routes through HBONE to cluster2's MCP server; agent never knows where the tool lives | None |
| FED-02 | Bidirectional Federation (cluster2 → cluster1) | Agent on cluster2 makes the symmetric call; cluster2's gateway routes back to cluster1; **proves the architecture is a true distributed mesh, not hub-and-spoke** | None |
| FED-03 | Composite Server / Single URL | One `tools/list` against the gateway returns a merged catalog from three backends (local + remote); the agent treats them as one server | None |

## Run

```bash
KUBE_CONTEXT=cluster1  KUBE_CONTEXT2=cluster2 \
  ./POC-Success-Criteria-v2/Phase3-Federated-MCP-Mesh/validate.sh
```

The script is interactive and read-only. Both kubeconfig contexts must be reachable.

## Prerequisites

| Component | Where | Verification |
|-----------|-------|--------------|
| `cluster1` and `cluster2` kubeconfig contexts | — | `kubectl config get-contexts cluster1 cluster2` |
| `mcp-route-remote` HTTPRoute + `mcp-backends-remote` AgentgatewayBackend | `agentgateway-system` (cluster1) | targets cluster2 via `mesh.internal` host |
| `mcp-route-cluster1` HTTPRoute + `mcp-backends-cluster1` AgentgatewayBackend | `agentgateway-system` (cluster2) | static host pointing at cluster1's external LB |
| East-west gateways | `istio-eastwest` (both clusters) | HBONE listeners 15008 + 15012 |
| `mcp-server-everything` | `agentgateway-system` (both clusters) | the actual tool being called |
| `netshoot` (or local curl host) | `debug` (cluster1) or local | request originator |

## FED-01 — Cross-Environment Federation (cluster1 → cluster2)

### What we're proving

The MCP Gateway is the single endpoint an agent talks to. When the agent requests a tool whose backend lives in another cluster, the gateway forwards the call over the HBONE tunnel — encrypted, identity-bound, and crucially **without** the agent needing to know the topology.

For the customer this is the answer to *"how does an agent in reai talk to an MCP server in Networks?"* — they don't, directly. They talk to their local MCP Gateway, which talks to Networks' MCP Gateway over HBONE.

### What the script does

1. Resolve cluster1's `agentgateway-hub` external LB hostname.
2. From `netshoot` on cluster1, run `send-traffic.sh --remote` (or its inline equivalent): MCP `initialize` → `tools/list` → `tools/call` against `http://<lb>/mcp/remote`.
3. Confirm the tool response came from cluster2's `mcp-server-everything` (the response payload includes the cluster identifier).

### What success looks like

- HTTP 200 on every step of the MCP flow.
- The tool response references cluster2 (e.g. via `get-env` returning the cluster's environment variable, or matching pod name).
- Round-trip latency in the order of milliseconds (HBONE adds ~1-3 ms typical).

## FED-02 — Bidirectional Federation (cluster2 → cluster1)

### What we're proving

If the architecture is a true mesh, traffic flows in both directions, symmetrically. This test runs the same scenario as FED-01 but originating from cluster2's gateway: an agent (or curl) hitting cluster2's `agentgateway-spoke` LB at `/mcp/remote` should be routed back to cluster1's MCP server.

The reason this matters: a hub-and-spoke model would have only one direction work. A distributed-mesh model has both. The customer's Enterprise Architects asked specifically whether adding a third environment would require touching only that environment, or also the existing ones. The answer is "only the new one", and **this test is the demonstration**.

### What the script does

1. Resolve cluster2's `agentgateway-spoke` external LB hostname.
2. Run the same MCP flow as FED-01 but against cluster2's LB: `http://<cluster2-lb>/mcp/remote`.
3. Confirm the tool response came from cluster1.

### What success looks like

- HTTP 200 across the flow.
- The tool response references cluster1 (mirroring FED-01 in the opposite direction).

### Caveats

- The cluster2 → cluster1 path uses a static host pointing at cluster1's external LB (set during install). If cluster1's LB is recreated, the static host needs updating. This is a current implementation detail; future versions will discover peers dynamically via Gloo Mesh's east-west service registry.

## FED-03 — Composite Server / Single URL

### What we're proving

A single MCP Gateway route can fan out to multiple backend MCP servers (any mix of local and remote) and present the union of their tools as one merged `tools/list` to the agent. The agent does not see three connections, three URLs, three sessions — it sees one MCP server with all tools available.

For the customer this answers *"do we have to expose a separate URL per tool team?"* The answer is no — a platform team can stitch together everyone's tools behind one stable URL.

### What the script does

1. Confirm the `agentgateway-hub` Service has a route configured to use multiple `AgentgatewayBackend` resources (a "virtual MCP" / composite-server route).
2. Open an MCP session on that route.
3. Call `tools/list` and confirm the response contains tools from at least two distinct backends (local + remote).
4. Call one tool from each backend and confirm both succeed.

### What success looks like

- `tools/list` returns a list whose names span multiple backends.
- `tools/call` succeeds for tools sourced from each backend.
- The agent's session ID is consistent across calls; the gateway handles upstream routing.

### Caveats

- Composite-server config is documented at https://docs.solo.io/agentgateway/2.2.x/mcp/virtual/ — if the demo cluster does not have a virtual/composite route applied yet, the script prints the manifest needed and exits with a notice.

## What this phase deliberately does NOT cover

- **Identity propagation across clusters.** The agent's JWT is enforced at the *first* gateway it hits (the local one). Whether to re-validate at the peer gateway is a policy choice — covered in Phase 5 (AUTH-04 token exchange) when relevant.
- **Cross-cluster registry propagation.** The Agent Registry today does not push config to remote MCP Gateways automatically. Phase 1 covers single-cluster lifecycle.
- **Failover policy.** What happens if cluster2 is unreachable? The default is a fail-fast 503 from cluster1's gateway. Configurable failover behaviour is a separate plan-of-record item, not validated here.
