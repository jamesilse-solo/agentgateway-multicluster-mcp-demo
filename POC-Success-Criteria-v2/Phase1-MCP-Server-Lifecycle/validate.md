# Phase 1 — MCP Server Lifecycle

> **Kubernetes Gateway API v1.4.0 (standard channel)** required. CR-02 creates an `HTTPRoute` (`gateway.networking.k8s.io/v1`) and an `AgentgatewayBackend` (`agentgateway.dev/v1alpha1`) — both must be installed before this phase runs. See [`../README.md`](../README.md#kubernetes-gateway-api-requirements) for the full version + CRD matrix.

> Validates **CR-01, CR-02, CR-03** — the end-to-end flow of registering a new MCP server, propagating that registration to the MCP Gateway, and calling the new tool from an agent.

This phase exists because, in customer conversations, the single most-asked-for capability has been: *"How do we onboard a new MCP server without rewriting agent code or hand-editing gateway config?"* The lifecycle below answers that.

## The flow this phase proves

```
Developer  ──POST /v0/servers──▶  Agent Registry  ──propagate──▶  MCP Gateway  ──route──▶  MCP Server
   (CR-01)                                              (CR-02)                  (CR-03)
                                          │
                                          ▼
                                       (admin
                                       approval — UI)
```

1. **CR-01 — Register.** A developer (or a CI/CD pipeline) publishes a new MCP server entry to the Agent Registry. The Registry stores it and exposes it through its discovery API. Other agents and admins can immediately find it by name, by namespace, or by free-text search.
2. **CR-02 — Propagate.** The new entry needs to be reflected in the MCP Gateway as a routable backend (an `AgentgatewayBackend` plus the matching `HTTPRoute`). Today, the bridge from Registry to Gateway is a **shell script** that reads the Registry's API and writes the gateway resources. **Native propagation** (the Registry directly programming the gateway via a controller) is on the product roadmap. This test executes whichever path is currently in place.
3. **CR-03 — Consume.** An agent uses the Registry's discovery API to look up the URL of the new tool, opens an MCP session through the gateway, and successfully calls a tool. No code change in the agent; no hand-edited gateway YAML.

## What success looks like

- After CR-01, `GET /v0/servers?search=<name>` returns the new entry — including its URL, JSON schema reference, version, and any title/description fields.
- After CR-02, `kubectl get agentgatewaybackend` and `kubectl get httproute` show new resources matching the registered server. The MCP Gateway data plane has reconciled them (the `Programmed` condition on the HTTPRoute is `True`).
- After CR-03, an MCP `initialize` followed by `tools/list` and `tools/call` returns a successful tool response. The full round-trip latency, identity, and tool name appear in the gateway's telemetry (verifiable in Phase 7).

## What this phase deliberately does NOT cover

- **Admin approval workflows.** The Agent Registry Enterprise UI exposes an admin-approval queue, but it is a UI flow, not a script-friendly action. Reviewers should use the UI to demonstrate this; the script will note the manual step at the appropriate point.
- **Cross-cluster propagation.** Today the Registry on the central environment (e.g. reai) does *not* automatically push config to remote MCP Gateways (e.g. on the Networks or on-prem environment). That capability is on the engineering roadmap but not yet GA. Phase 3 covers cross-cluster *routing*; this phase stays single-cluster.
- **Schema validation of the registered URL.** The Registry validates that the URL host matches the namespace prefix (e.g. `com.amazonaws/...` expects `*.amazonaws.com`), but this is more an anti-squatting check than a security boundary. Treated as ambient correctness here.

## Tests in this phase

| ID | Requirement | What success proves | Net cluster change |
|----|-------------|---------------------|--------------------|
| CR-01 | Register a new MCP server entry via the Registry API | The Registry is the single catalog for every approved tool — discoverable by name, no out-of-band sharing of URLs | One Registry entry created (deleted at end of run) |
| CR-02 | Propagate the entry from the Registry to the MCP Gateway | New tool is routable through the gateway without restart, hand-edited YAML, or agent code changes | One `AgentgatewayBackend` + one `HTTPRoute` created (deleted at end of run) |
| CR-03 | Agent looks up the tool by name and successfully calls it | End-to-end onboarding: register → propagate → discover → call, with zero per-tool agent code | None |

## Run

```bash
KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase1-MCP-Server-Lifecycle/validate.sh
```

The script is interactive — press **Enter** at each step. The Registry port-forward (`localhost:8080`) is opened automatically and torn down at the end.

## Prerequisites

| Component | Namespace | Verification |
|-----------|-----------|--------------|
| `cluster1` kubeconfig context | — | `kubectl config get-contexts cluster1` |
| Agent Registry Enterprise (`agentregistry-agentregistry-enterprise`) | `agentregistry` | `kubectl --context cluster1 -n agentregistry get pod -l app.kubernetes.io/name=agentregistry-enterprise` |
| `agentgateway-hub` Gateway with external LB | `agentgateway-system` | `kubectl --context cluster1 -n agentgateway-system get gateway agentgateway-hub` |
| `mcp-server-everything` (or any in-cluster MCP server) | `agentgateway-system` | `kubectl --context cluster1 -n agentgateway-system get deploy mcp-server-everything` |
| `netshoot` debug pod | `debug` | `kubectl --context cluster1 -n debug get pod -l app=netshoot` |

## Step-by-step (what the script actually does)

### CR-01 — Register a new MCP server entry

1. Open a port-forward to the Agent Registry API (`svc/agentregistry-agentregistry-enterprise` → `localhost:8080`).
2. `POST /v0/servers` with a JSON body containing a unique `name` (under `com.amazonaws/...` namespace), a `remotes[]` entry pointing at the gateway's `/mcp` path, and a schema reference.
3. Wait briefly for write to settle.
4. `GET /v0/servers?search=<name>` and confirm the entry appears.

**Why this matters:** Up to now, a "new tool" was a YAML PR — multiple repos, multiple owners, multiple approvers. With the Registry as source of truth (executive decision in a 2026-04-28 sync), one API call (or UI form) is the entire registration surface.

### CR-02 — Propagate to the MCP Gateway

1. Run the propagation script (interim path) that reads the Registry and produces the matching `AgentgatewayBackend` + `HTTPRoute`.
2. `kubectl get agentgatewaybackend` and `kubectl get httproute` to confirm the new resources exist.
3. Wait for the HTTPRoute's `Accepted` and `ResolvedRefs` conditions to be `True` (controller reconciliation).

**Why this matters:** This is the seam between the Registry's intent ("this tool exists, here's its URL") and the gateway's reality ("a request to `/mcp/<tool>` goes here"). Today it's a shell script. The native version is on the roadmap and will replace this step transparently.

> **If the propagation script is not yet present in the repo:** the test prints the manual `kubectl apply` equivalent and continues. Either path validates the same outcome — that the Registry's view becomes the gateway's view.

### CR-03 — Agent calls the newly registered tool

1. From inside the `netshoot` pod, query the Registry's discovery API to resolve the new server's URL.
2. Open an MCP session: `POST /mcp` with `method: initialize`. Capture the `Mcp-Session-Id`.
3. `POST /mcp` with `method: tools/list` — confirm the new server's tools appear.
4. `POST /mcp` with `method: tools/call` — exercise one tool and confirm a successful response.

**Why this matters:** The agent doesn't know (or care) that this tool was added five minutes ago. It uses the same discovery → connect → call pattern it uses for every other tool. That's the property the Registry-as-source-of-truth model is supposed to provide.

### Cleanup

The script deletes the test registration and any propagated `AgentgatewayBackend` / `HTTPRoute` so the cluster ends in the same state it started. The port-forward is closed.

## Caveats and known limitations

- **Native propagation timing.** As of writing, the path from Registry to MCP Gateway is a shell-script bridge; native (`AgentRegistry → controller → gateway`) is targeted but not yet GA. The script attempts the script-bridge path and falls back to the manual `kubectl apply` if the script isn't present.
- **Cross-cluster registration.** The central Registry does not push config to MCP Gateways in other environments today. If you need a tool on Cluster 2, register it against the Registry on Cluster 2 (or apply gateway resources directly there) until cross-cluster propagation lands.
- **Approval workflow.** The Enterprise UI's admin-approval flow is a separate UI demonstration — the API path used here bypasses it. Reviewers using the UI should approve manually, then re-run CR-02/CR-03.
- **Custom Registry image dependency.** During the demo period, the propagation behaviour requires the custom `pmuir/agentregistry-server:add-agentgateway-resource` image. The release version of the chart will replace it.
