# Adding MCP Servers to AgentGateway

This guide shows the three patterns for exposing an MCP server through AgentGateway, plus how to restrict which tools an agent can actually call.

The accompanying helper script — [`add-mcp-server.sh`](add-mcp-server.sh) — automates the YAML; this doc explains what it produces and why.

---

## Resource model

Two resources turn an MCP endpoint into a routable backend on the gateway. A third is needed only when the destination service lives in a different namespace from the gateway.

| Resource | API group | What it does |
|----------|-----------|--------------|
| `AgentgatewayBackend` | `agentgateway.dev/v1alpha1` | Describes the MCP endpoint (the target host, port, transport, optional TLS) and tells AgentGateway "this is an MCP-protocol backend, not a plain HTTP one." Used as the `backendRef` of an HTTPRoute. |
| `HTTPRoute` | `gateway.networking.k8s.io/v1` (Kubernetes Gateway API) | Standard path-based routing rule attached to the AgentGateway `Gateway`. Matches a path prefix (e.g. `/mcp/search`) and points at the AgentgatewayBackend. |
| `ReferenceGrant` | `gateway.networking.k8s.io/v1beta1` | Cross-namespace permission: lets an HTTPRoute in namespace A reference an AgentgatewayBackend (or Service) in namespace B. Without it, the gateway controller refuses the reference. |

The gateway itself — `agentgateway-hub` in `agentgateway-system` — is installed once via `scripts/01-install.sh` and configured via `scripts/02-configure.sh`. Every new MCP server is just a backend + route on top of that existing gateway.

---

## Pattern 1 — Local MCP server (same cluster, same namespace)

The MCP server is an in-cluster `Deployment` + `Service` in the same namespace as the gateway. This is the simplest case.

```yaml
# 1. Backend — declares the MCP endpoint
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-everything-local
  namespace: agentgateway-system
spec:
  mcp:
    failureMode: FailOpen           # On upstream failure, return a JSON-RPC error rather than dropping the connection
    targets:
    - name: mcp-server-everything   # Arbitrary identifier (shown in traces)
      static:
        host: mcp-server-everything.agentgateway-system.svc.cluster.local
        port: 80
---
# 2. Route — exposes the backend at /mcp/local on the existing gateway
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-local
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-hub          # The existing AgentGateway Gateway resource
    namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/local
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-everything-local
      namespace: agentgateway-system
```

Agents now reach this server at `http://<agw-lb>/mcp/local`.

## Pattern 2 — External (off-cluster) MCP server

The MCP server lives outside the cluster — a public SaaS endpoint, a partner API, or a self-hosted service on a different VPC. The pattern is identical to Pattern 1; only the `host` and TLS settings change.

This is what the demo uses for the Solo.io documentation search MCP server at `https://search.solo.io/mcp`:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: search-solo-io-backend
  namespace: agentgateway-system
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: search-solo-io
      static:
        host: search.solo.io       # Public DNS name
        port: 443                  # HTTPS
      tls:
        insecure: false            # Default; production should validate the upstream cert chain
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-search
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/search
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: search-solo-io-backend
      namespace: agentgateway-system
```

Agents call `http://<agw-lb>/mcp/search` and the gateway terminates the agent's connection, validates auth, applies any rate limits, then opens an outbound HTTPS connection to `search.solo.io:443`. The SaaS sees one connection per gateway pod — perfect for IP allowlists.

The mesh's egress gateway (`Phase4-Egress-and-DLP` in `POC-Success-Criteria-v2/`) can additionally pin all such egress to a single stable source IP for partner-side firewall rules.

## Pattern 3 — Cross-namespace MCP server (ReferenceGrant)

The MCP `Service` lives in a different namespace from the gateway — common when a tool team owns its own namespace and the platform team owns `agentgateway-system`. Two routing variants:

**Variant A — backend in the tool team's namespace**

```yaml
# Backend in the tool team's namespace
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: tickets-backend
  namespace: support-tools
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: tickets-mcp
      static:
        host: tickets-mcp.support-tools.svc.cluster.local
        port: 80
---
# Route in the gateway's namespace, referencing the backend cross-namespace
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route-tickets
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-hub
    namespace: agentgateway-system
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp/tickets
    backendRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: tickets-backend
      namespace: support-tools          # ← cross-namespace reference
---
# Permission for the HTTPRoute (in agentgateway-system) to reference the
# AgentgatewayBackend (in support-tools). Without this, the gateway controller
# rejects the route with "BackendNotPermitted".
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: agw-to-tickets-backend
  namespace: support-tools             # In the *destination* namespace
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: agentgateway-system     # The route lives here
  to:
  - group: agentgateway.dev
    kind: AgentgatewayBackend
    name: tickets-backend              # Optional — omit to grant for all backends in the namespace
```

**Variant B — route in the tool team's namespace**

The HTTPRoute itself can live in the tool team's namespace, attached to the gateway in `agentgateway-system`. In that case the ReferenceGrant goes the other way (grants HTTPRoutes in the team namespace permission to attach to the Gateway in `agentgateway-system`):

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: tickets-to-agw-gateway
  namespace: agentgateway-system       # In the Gateway's namespace
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: support-tools
  to:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-hub
```

Choose Variant A when the platform team controls the routing policy (URL paths, traffic splits) and Variant B when the tool team owns its routing rules end-to-end.

---

## Restricting tools — RBAC inside a single MCP server

An MCP server typically exposes many tools (`search`, `list_repos`, `delete_repo`, etc.). Some are safe to expose broadly; others should be admin-only. AgentGateway can filter the **`tools/list`** response and reject **`tools/call`** for tools an agent identity isn't entitled to.

### Tool filtering on the backend

The most explicit way: declare an allowlist on the `AgentgatewayBackend` so the gateway only ever surfaces those tools. This is appropriate when a *whole* tier of agents is meant to use only a subset.

Example — restrict the Solo.io search MCP server to **only the `search` tool**, hiding any future tools the server adds:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: search-solo-io-search-only
  namespace: agentgateway-system
spec:
  mcp:
    failureMode: FailOpen
    targets:
    - name: search-solo-io
      static:
        host: search.solo.io
        port: 443
      filter:
        toolAllowlist:               # Only these tools are exposed
        - search
```

After applying this, agents calling `tools/list` against `/mcp/search` see exactly one tool (`search`); attempts to call any other method get an MCP permission error from the gateway *without ever reaching `search.solo.io`*.

### Per-identity tool RBAC (OPA)

When different agent identities need different tool sets on the *same* backend, use an OPA Rego policy in ExtAuth. The policy parses the JSON-RPC method + tool name from the request body and decides per call. Pattern:

```rego
package mcp.rbac
default allow := false

# Allow `search` for everyone authenticated
allow if {
  input.body.method == "tools/call"
  input.body.params.name == "search"
}

# Allow other tools only for admin role
allow if {
  input.body.method == "tools/call"
  input.body.params.name != "search"
  input.jwt.role == "admin"
}
```

Wire the policy with an `AuthConfig` referencing an OPA `ConfigMap` and an `EnterpriseAgentgatewayPolicy` attaching it to the route. Full pattern documented at <https://docs.solo.io/agentgateway/2.3.x/security/extauth/opa/>.

---

## Helper script

[`add-mcp-server.sh`](add-mcp-server.sh) generates the right combination of resources for any of the three patterns:

```bash
# Pattern 1 — local
./demo/add-mcp-server.sh \
  --name my-local-tool \
  --path /mcp/local \
  --host mcp-server-everything.agentgateway-system.svc.cluster.local \
  --port 80

# Pattern 2 — external (HTTPS)
./demo/add-mcp-server.sh \
  --name search-solo-io \
  --path /mcp/search \
  --host search.solo.io \
  --port 443 \
  --tls

# Pattern 2 with tool allowlist
./demo/add-mcp-server.sh \
  --name search-solo-io \
  --path /mcp/search \
  --host search.solo.io \
  --port 443 --tls \
  --tool-allowlist search

# Pattern 3 — cross-namespace (creates the ReferenceGrant)
./demo/add-mcp-server.sh \
  --name tickets-mcp \
  --path /mcp/tickets \
  --host tickets-mcp.support-tools.svc.cluster.local \
  --port 80 \
  --backend-namespace support-tools
```

The script prints the YAML it's about to apply (`--dry-run` shows it without applying).

---

## Where this fits in the demo

- **Slide 5 (Gateway)** — sets up why every MCP call flows through one policy point.
- **Slide 5a (External MCP)** — uses `search.solo.io` to show that "external" looks identical to "internal" from the agent's point of view.
- **Slide 6a (Tool RBAC)** — shows the `toolAllowlist` filter restricting `search.solo.io` to only the `search` tool.
- **POC-Success-Criteria-v2/Phase5-Identity-and-Access** — `AUTH-03` is the validation test for two-level tool filtering.
- **POC-Success-Criteria-v2/Phase4-Egress-and-DLP** — `EGR-01` validates the egress-gateway path that makes external SaaS access auditable.
