# Phase 7 — Observability

> Validates **OBS-01, OBS-02** — the trace + metric story that makes this platform operable. The customer cares about two questions: *"can I see one trace that spans clusters when an agent calls a federated tool?"* and *"can I see token consumption per model and per agent?"* Both are answered by the management UI fronting the OTel collector + ClickHouse stack.

This phase consolidates v1's CP-05 (distributed tracing) and adds OBS-02 (token usage) — surfaced as a customer ask in the 2026-04-30 sync.

## What this phase proves

1. **End-to-end traces span clusters.** A single trace tree shows an agent's call traversing the local MCP Gateway, the HBONE tunnel, the peer gateway, and the upstream MCP server. (OBS-01)
2. **Per-model + per-agent metrics are first-class.** The management UI shows token consumption broken down by model, by agent identity, by tool — without running a separate observability product. (OBS-02)

## Tests in this phase

| ID | Requirement | What success proves | Net cluster change |
|----|-------------|---------------------|--------------------|
| OBS-01 | OTel Distributed Tracing | One trace tree spans `agent → MCP Gateway (cluster1) → HBONE → MCP Gateway (cluster2) → tool`. Spans carry tool name, identity, and latency. | None |
| OBS-02 | Token Usage & Model Breakdown | Management UI surfaces per-model token counts, error rates, latency percentiles, and per-agent breakdown — sourced from gateway-emitted spans. | None |

## Run

```bash
KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase7-Observability/validate.sh
```

## Prerequisites

| Component | Namespace | Why |
|-----------|-----------|-----|
| `EnterpriseAgentgatewayParameters/agentgateway-config` | `agentgateway-system` | gateway must be configured to emit traces (OTLP gRPC) and metrics (LLM fields) |
| `solo-enterprise-telemetry-collector` | `agentgateway-system` | OTel collector receiving gateway spans |
| `agw-management-clickhouse` (StatefulSet) | `agentgateway-system` | trace + metric storage |
| `solo-enterprise-ui` | `agentgateway-system` | management UI on `localhost:4000` (port-forward) |
| `agentgateway-hub` external LB | — | endpoint generating traffic |

The management chart bundling the collector, ClickHouse, and UI is `oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management:0.3.12`. Without this chart, both tests fail.

## OBS-01 — OTel Distributed Tracing

### What we're proving

When an agent calls a federated tool, multiple infrastructure hops are involved. Without distributed tracing, debugging — or even just answering "where did that latency come from?" — is impossible. With OTel + the gateway's tracing config, every hop emits a span with shared trace context. The spans roll up into one tree.

For the customer: this is also the audit story. The trace tree is the answer to "show me everything that happened when this agent called this tool at this time."

### What the script does

1. Confirm the gateway's `EnterpriseAgentgatewayParameters` has `rawConfig.config.tracing.otlpEndpoint` pointing at the local collector.
2. Confirm the collector pod is `Running` and free of recent export errors.
3. Generate traffic: a federated `tools/call` (cluster1 → cluster2 via `/mcp/remote`).
4. Wait briefly for ClickHouse to ingest.
5. Open the management UI on `localhost:4000` and navigate to **Traces** (or use the API endpoint to query trace count).

### What success looks like

- Gateway config shows `otlpEndpoint: http://solo-enterprise-telemetry-collector...:4317`.
- Collector logs are clean — no `Database platformdb does not exist` or repeated export failures.
- After traffic, trace count in ClickHouse increases.
- The UI's Traces view shows a tree spanning the federated call, with spans for `agent`, `gateway-cluster1`, `gateway-cluster2`, and the upstream MCP server.

### Caveats

- ClickHouse schema migration runs at UI pod startup — if the UI pod was running before the database was reachable (or the database was reset), the schema may not exist. Restarting `solo-enterprise-ui` re-runs the migration.
- Span emission requires `EnterpriseAgentgatewayParameters` AND the GatewayClass to have `parametersRef` pointing at it. Both are set during install (`scripts/03-agw.sh` or equivalent); the `helm get values enterprise-agentgateway` output should include `gatewayClassParametersRefs`.

## OBS-02 — Token Usage & Model Breakdown

### What we're proving

Without aggregated metrics, "how much did agents spend on LLMs this month" is an end-of-month invoice mystery. With per-model + per-agent counters at the gateway, finance and platform teams have real-time answers — and per-team chargeback becomes feasible.

The metrics come from the gateway's `EnterpriseAgentgatewayParameters` configuration:
- `metrics.fields.add.user_id`: extracts agent ID from headers
- `logging.fields.add.llm.cached_tokens` / `.reasoning_tokens` / `.prompt` / `.completion`: capture per-call LLM token counts

These flow to ClickHouse via the OTel collector and surface in the management UI's traffic / metrics panes.

### What the script does

1. Send a varied burst of MCP calls — different `x-agent-id` headers, different tool names. (If an LLM-bearing path is configured, exercise it; otherwise ordinary tool calls also produce per-agent metrics.)
2. Open the UI on `localhost:4000` and navigate to **Sessions** / **Traffic** / **Metrics**.
3. Confirm panels populate with:
   - Per-agent breakdown
   - Per-model breakdown (if LLM fields are emitted)
   - Latency percentiles
   - Error rate

### What success looks like

- After traffic, the UI shows non-empty data in every relevant panel.
- Filtering by agent ID returns only that agent's calls.
- Latency / error / token counts are non-zero.

### Caveats

- LLM-specific metrics (`prompt`, `completion`, `cached_tokens`) require the gateway to be passing through traffic with an LLM upstream that emits those values. If the demo cluster doesn't have an LLM connector configured, the per-tool metrics still populate but the LLM-specific panels stay empty — that's expected for the bare MCP demo.
- A common cause of "No data available" panels is missing `metrics.fields` configuration in `EnterpriseAgentgatewayParameters`. The script prints the current rendered config so reviewers can confirm.

## What this phase deliberately does NOT cover

- **Alerting and on-call.** A trace + metric backend is the foundation; integration with PagerDuty / Slack / etc. is a customer-side concern.
- **Custom Grafana dashboards.** The management UI is the in-product surface; bespoke Grafana dashboards using the same data are out of scope here.
- **Long-term trace retention.** ClickHouse storage and retention windows are operational concerns; defaults are fine for demo and POC.
