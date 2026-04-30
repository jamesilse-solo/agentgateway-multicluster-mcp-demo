# Script 09 — Optional POC Components

This script installs the additional components needed to prove the POC success criteria that the core installation scripts (`01` through `08`) do not cover. Each section is independently runnable.

```bash
# Run all sections
KUBE_CONTEXT=cluster1 ./09-optional-components.sh

# Run specific sections only
SECTIONS=4,6 KUBE_CONTEXT=cluster1 ./09-optional-components.sh

# Section 7 (Keycloak) must be opted into explicitly
SECTIONS=7 KUBE_CONTEXT=cluster1 ./09-optional-components.sh
```

---

## Section 1 — Istio Egress Gateway + Egress Policy

**Proves:** MESH-08, MESH-09

### What it is

An Istio **egress gateway** is a dedicated Envoy proxy that acts as a controlled exit point for traffic leaving the cluster. Instead of each application pod using a random node IP as its source address when calling external SaaS APIs, all egress traffic is channeled through the egress gateway's single, stable IP address.

The `outboundTrafficPolicy: REGISTRY_ONLY` mesh configuration setting blocks outbound connections to any hostname that is not registered in the Istio service registry via a `ServiceEntry`. Combined with the egress gateway, this creates a two-layer control: you must register a destination _and_ all traffic to that destination exits through the controlled gateway pod.

### Why it's needed

| Criteria | Without this | With this |
|----------|-------------|-----------|
| MESH-08 — Centralized SaaS Egress | Each agent pod uses a different source IP per node | SaaS vendors see one static IP → simple IP allowlisting |
| MESH-09 — Exfiltration Cage | A prompt-injected agent can POST data to any internet host | Unregistered destinations are blocked at the mesh layer before the packet leaves the node |

### What gets deployed

- `istio-egressgateway` Deployment + LoadBalancer Service (Helm, same image as ingress/east-west gateway)
- `ServiceEntry` for `search.solo.io` (the reference SaaS MCP tool in the validate scripts)
- `Gateway` + `VirtualService` to route `search.solo.io:443` through the egress gateway pod
- Patch to `istio` ConfigMap in `istio-system` setting `outboundTrafficPolicy: REGISTRY_ONLY`

> **Warning:** `REGISTRY_ONLY` is a cluster-wide change. Any external host without a `ServiceEntry` will be unreachable after this is applied. Add `ServiceEntry` resources for all required external endpoints _before_ enabling this step.

---

## Section 2 — OPA Tool RBAC + Task-Based Access Control

**Proves:** SEC-02, SEC-03

### What it is

**Open Policy Agent (OPA)** is a general-purpose policy engine that evaluates Rego policies against arbitrary JSON input. In this setup, OPA runs as an evaluation step _inside_ the ExtAuth pipeline rather than as a standalone sidecar.

**Tool RBAC (SEC-02):** The Rego policy parses the `tools/call` JSON-RPC body, extracts the `params.name` field (the tool being invoked), and checks whether the caller's JWT `role` claim grants access to that tool. An `agent` role cannot call `delete_database`; only `admin` can.

**Task-Based Access Control — TBAC (SEC-03):** A second Rego policy checks the `task` JWT claim — a field the orchestrator system (LangChain, CrewAI, etc.) injects when minting the agent's token. The policy maps each task context to an allowed set of tool names. An agent with `task: customer-support` cannot call `write_file` even if its `role` would normally permit it. This is the important distinction from role-based access: the _context_ of what the agent is doing constrains what it can touch, not just who it is.

### Why it's needed

Both controls operate at the gateway with zero changes to the MCP servers themselves. The LLM cannot bypass the policy by hallucinating a tool name — the gateway evaluates the JSON-RPC body before it reaches the server.

### What gets deployed

- `ConfigMap/opa-tool-rbac` — Rego policy for role × tool matrix (SEC-02)
- `ConfigMap/opa-tbac` — Rego policy for task × tool matrix (SEC-03)
- `AuthConfig/oidc-with-opa` — replaces the existing Dex-only AuthConfig, chaining OIDC → OPA RBAC → OPA TBAC
- Patch to the `oidc-extauth` `EnterpriseAgentgatewayPolicy` to reference the new AuthConfig

> **Note:** After applying, restart the ExtAuth service pod so it picks up the new ConfigMap modules:
> `kubectl -n agentgateway-system rollout restart deploy/ext-auth-service-enterprise-agentgateway`

---

## Section 3 — Upstream Credential Injection

**Proves:** SEC-06

### What it is

When an agent calls a SaaS MCP tool (e.g., a Jira connector), the tool requires its own authentication credential — an API key, OAuth token, or service account JWT. Without upstream credential injection, the agent would need to possess and transmit those credentials, creating a secret management problem in every agent's runtime environment.

The ExtAuth pipeline can inject upstream credentials _after_ the agent's own identity has been validated and _before_ the request is forwarded to the MCP server. The agent presents a gateway-level JWT; the gateway swaps in the SaaS API key from a Kubernetes Secret. The agent never sees or handles the upstream credential.

### Why it's needed

| Without | With |
|---------|------|
| Agent binary or prompt must carry SaaS API keys | Credentials stored in Kubernetes Secrets, mounted only in the gateway |
| Credential rotation requires redeploying every agent | Rotate the Secret; no agent change required |
| Logs or prompt leaks expose SaaS keys | Agent token and SaaS key are decoupled |

### What gets deployed

- `Secret/upstream-saas-apikey` — placeholder API key (replace in production)
- `AuthConfig/upstream-credential-injector` — ExtAuth config that injects `x-upstream-api-key` header from the Secret
- `EnterpriseAgentgatewayPolicy/upstream-credential-injection` — scoped to the MCP route

---

## Section 4 — Rate Limiting

**Proves:** GR-03

### What it is

A **RateLimitConfig** sets a request-per-minute cap on the AgentGateway. The counter is keyed on the `x-user-token` header that ExtAuth populates from the JWT email claim, so each agent identity gets an independent counter backed by the Redis instance (`ext-cache`) already deployed with AgentGateway Enterprise.

When an agent exceeds the limit, the gateway returns HTTP 429 with a JSON-RPC-formatted error body. The agent's reasoning loop can catch this and back off rather than hammering the MCP server.

### Why it's needed

Without a rate limit, a misbehaving or prompt-injected agent can issue thousands of `tools/call` requests per second, exhausting the MCP server's resources or incurring unexpected SaaS API costs. Rate limiting is a last-resort backstop that sits entirely in the gateway — the MCP server never needs to implement it.

### What gets deployed

- `RateLimitConfig/mcp-per-agent-limit` — 10 requests/minute per agent JWT (tune for production)
- Patch to the `oidc-extauth` `EnterpriseAgentgatewayPolicy` referencing the config

> **Note:** The `ext-cache` Redis pod is already running (deployed by AGW Enterprise). The `rateLimitServer` Helm value must be enabled in the AGW chart values for the rate limit service to connect to it.

---

## Section 5 — ExtProc Guardrail Webhook

**Proves:** GR-01

### What it is

**External Processing (ExtProc)** is an Envoy feature where every request and response body is streamed to an external gRPC service before being forwarded. The gateway buffers the payload, sends it to the ExtProc service, waits for a (possibly modified) response, then forwards the cleaned payload to the upstream MCP server.

The canonical production use case is PII scrubbing: the ExtProc service parses the JSON-RPC body, detects sensitive fields (SSNs, credit card numbers, health data), redacts them, and returns the sanitized body. The MCP server never receives the raw PII.

**GatewayExtension** is the AgentGateway CRD that configures which ExtProc gRPC service to call and which parts of the request/response to process (headers only, full body buffering, streaming, etc.).

### Why it's needed

MCP tool calls frequently pass user-originated content as tool arguments (e.g., "summarize this email thread: ..."). Without a guardrail at the gateway layer, PII flows directly from the agent's input into the MCP server logs, the SaaS backend, and any intermediate logging infrastructure. The gateway is the only point that sees every payload for every agent without requiring instrumentation in each MCP server.

### What gets deployed

- `ConfigMap/ext-proc-server` — Python gRPC passthrough implementation of `envoy.service.ext_proc.v3.ExternalProcessor`
- `Deployment/ext-proc-guardrail` — runs the Python server (`python:3.12-slim` + `envoy-data-plane`)
- `Service/ext-proc-guardrail` — exposes port 9001 for gRPC
- `GatewayExtension/pii-guardrail` — configures request header + body processing mode
- Patch to `oidc-extauth` `EnterpriseAgentgatewayPolicy` wiring the extension to the gateway

> **Production replacement:** The passthrough implementation proves the wiring but performs no scrubbing. For real PII detection replace the container with one of:
> - **F5 AI Gateway (Calypso)** — commercial, purpose-built for MCP guardrails
> - **Custom gRPC service** implementing `envoy.service.ext_proc.v3.ExternalProcessor` with a model-based or regex-based PII detector

---

## Section 6 — OTEL Collector + Jaeger

**Proves:** CP-05

### What it is

AgentGateway Enterprise emits **OpenTelemetry (OTEL) traces** for every MCP call it handles. A trace records the full lifecycle of a request as a tree of spans: how long the gateway spent validating the JWT, routing the request, waiting for the upstream MCP server, and — in the cross-cluster case — the time the request spent in transit over the HBONE tunnel to the spoke cluster.

**OTEL Collector** receives these traces over gRPC (port 4317) and forwards them to a trace backend. **Jaeger** stores and visualizes the traces. A single `traceparent` header (W3C Trace Context) correlates all spans from a single MCP call across all hops.

### Why it's needed

Without traces, a slow `tools/call` is a black box. With traces:

- Platform team can see that 90% of latency is in the east-west HBONE tunnel vs. the MCP server itself
- An anomalous agent issuing 1000 tool calls per minute is immediately visible in the Jaeger service map
- Cross-cluster calls show both cluster1 (hub) and cluster2 (spoke) spans under the same trace ID

### What gets deployed

- `jaeger` Helm release (all-in-one, in-memory, no persistent storage — suitable for POC)
- `otel-collector` Helm release (`opentelemetry-collector-contrib`, deployment mode)
- `EnterpriseAgentgatewayPolicy/otel-tracing` — configures AGW to emit traces to the collector

> **After deployment:** Port-forward Jaeger and run Phase 7 validate.sh. The `traceparent` header appears in the AGW response, and searching for the trace ID in Jaeger shows the full cross-cluster span tree.
>
> Port-forward: `kubectl -n agentgateway-system port-forward svc/jaeger-query 16686:16686`

---

## Section 7 — Keycloak + Dynamic Client Registration (OPTIONAL)

**Proves:** SEC-05

### What it is

**Dynamic Client Registration (DCR)** is the OAuth 2.0 RFC 7591 protocol that allows a new client application to register itself with an Identity Provider _at runtime_ — obtaining a `client_id` and `client_secret` automatically — without requiring a human administrator to pre-create the client in the IdP console.

For MCP, DCR means a new AI agent can onboard to the platform in a fully automated pipeline: it POSTs a registration request to the IdP's `/clients-registrations` endpoint and receives credentials it uses to authenticate through the gateway. No manual IdP configuration step is needed.

**Dex** (used for the primary OIDC flow in this POC) does not implement RFC 7591. **Keycloak** does. This section deploys Keycloak as an additional IdP specifically to demonstrate the DCR flow.

### Why it's needed

In an enterprise with many agent deployments, manual IdP client registration creates an operational bottleneck. DCR enables self-service agent onboarding with cryptographically-verified, unique credentials per agent instance. It is the production answer to the question "how does a new agent get credentials without a service ticket?"

### What gets deployed

- `keycloak` Helm release (Bitnami chart, PostgreSQL backend) in the `keycloak` namespace
- `AuthConfig/oidc-keycloak-dcr` — separate AuthConfig referencing the Keycloak OIDC endpoint
- Manual steps documented for realm + DCR policy configuration (realm creation via Keycloak admin UI)

> **Resource note:** Keycloak + PostgreSQL requires approximately 2 vCPU and 2 GiB RAM. Ensure the cluster has capacity before running Section 7.
>
> Section 7 is excluded from the default `SECTIONS` list. Run with `SECTIONS=7` to opt in.

---

## Coverage Map

| Section | POC Criteria | Gap filled |
|---------|-------------|------------|
| 1 | MESH-08, MESH-09 | Egress gateway not deployed; `ALLOW_ANY` default |
| 2 | SEC-02, SEC-03 | OPA not configured in ExtAuth pipeline |
| 3 | SEC-06 | No upstream credential injection in AuthConfig |
| 4 | GR-03 | RateLimitConfig absent; Redis already running |
| 5 | GR-01 | GatewayExtension absent; no ExtProc webhook wired |
| 6 | CP-05 | OTEL Collector + Jaeger not deployed |
| 7 | SEC-05 | Dex does not support RFC 7591 DCR |
