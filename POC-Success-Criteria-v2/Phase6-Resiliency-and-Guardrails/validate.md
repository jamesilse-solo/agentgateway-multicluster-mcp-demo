# Phase 6 — Resiliency & Guardrails

> Validates **GR-01, GR-02** — the gateway-layer protections that keep the platform stable when traffic spikes or content needs inspection. This phase intentionally trims four v1 tests down to two; schema validation and graceful-error-translation tested default behaviour, not value claims.

## What this phase proves

1. **Pluggable content guardrails.** The gateway can hand off the JSON-RPC body to an external webhook (PII scrubber, prompt-injection detector, F5 Calypso) before forwarding it. The customer can reuse existing DLP/guardrail investments instead of buying a new product. (GR-01)
2. **Global rate limiting backed by Redis.** Counters live in a shared Redis (`ext-cache`), so limits are coherent across gateway replicas. The customer specifically called out wanting *global* limits, not per-pod, in the 2026-04-30 sync. (GR-02)

## Tests in this phase

| ID | Requirement | What success proves | Net cluster change |
|----|-------------|---------------------|--------------------|
| GR-01 | External Guardrails Webhook (ExtProc) | The gateway streams the request body to an external webhook for inspection/transformation; webhook decisions (allow / sanitize / block) propagate. | None (assumes a `GatewayExtension` is already configured) |
| GR-02 | Global Rate Limiting (Redis) | A `RateLimitConfig` of N requests/min is enforced *globally* across replicas via the shared Redis cache. Burst above the limit returns 429. | A `RateLimitConfig` resource is applied for the test and deleted afterward |

## Run

```bash
KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase6-Resiliency-and-Guardrails/validate.sh
```

## Prerequisites

| Component | Namespace | Why |
|-----------|-----------|-----|
| `agentgateway-hub` external LB | — | endpoint under test |
| Redis (`ext-cache-enterprise-agentgateway`) pod | `agentgateway-system` | rate-limiter backing store (GR-02) |
| `GatewayExtension` resource pointing at an ExtProc webhook | `agentgateway-system` | required for GR-01 (skipped with note if absent) |
| `RateLimitConfig` CRD | cluster | enforcement engine (GR-02) |

## GR-01 — External Guardrails Webhook (ExtProc)

### What we're proving

Customers have existing investments in DLP and prompt-injection detection (F5 Calypso, custom PII scrubbers, vendor-specific guardrails). Forcing them to choose between those and the gateway's built-in checks is a non-starter. With ExtProc, the gateway streams the JSON-RPC body to a webhook of the customer's choice; the webhook decides whether to allow, modify, or block. The gateway then forwards (or rejects) accordingly.

### What the script does

1. Confirm a `GatewayExtension` is configured pointing at the webhook endpoint.
2. Confirm an `EnterpriseAgentgatewayPolicy` references the `GatewayExtension`.
3. Send a benign tools/call — expect success.
4. Send a tools/call carrying a known-bad pattern (e.g. simulated PII like `SSN: 123-45-6789`). Depending on webhook configuration:
   - **Allow with sanitisation**: response contains scrubbed body; no 4xx.
   - **Block**: gateway returns a configured rejection code.
5. Inspect the webhook's logs (if accessible) to confirm it received and decided.

### What success looks like

- Benign request: 200.
- Bad request: either modified body in upstream (success path) or 4xx (block path) — depending on webhook policy.
- Webhook log shows the received payload.

### Caveats

- This test **requires a pre-configured webhook**. If the demo cluster doesn't have one wired up, the script prints the expected `GatewayExtension` + `EnterpriseAgentgatewayPolicy` manifests and exits informationally — the rest of the phase still runs.

## GR-02 — Global Rate Limiting (Redis)

### What we're proving

Per-pod rate limiting is a known anti-pattern: as the gateway scales out, the effective limit scales with it, defeating the purpose. The customer flagged this in the 2026-04-30 sync and asked for *global* rate limiting.

The mechanism is a `RateLimitConfig` resource referencing the shared `ext-cache` Redis. Every gateway replica writes counters to Redis, so limits are evaluated coherently across the fleet.

### What the script does

1. Confirm Redis (`ext-cache-enterprise-agentgateway`) is `Running`.
2. Apply a `RateLimitConfig` of `requestsPerUnit: 10, unit: MINUTE` keyed on a request header (e.g. `x-agent-id`).
3. Wait briefly for XDS propagation.
4. Send 15 rapid requests with a fixed `x-agent-id` header. Expect:
   - Requests 1-10 succeed.
   - Requests 11-15 return HTTP 429 (or the gateway's MCP-encoded equivalent).
5. Wait 60 seconds, send one more request — expect success (window reset).
6. Delete the `RateLimitConfig`.

### What success looks like

- Requests within the window: 200.
- Requests beyond the limit: 429 (or MCP "Overload" error).
- After window reset: 200 again.
- Redis key for the agent's identifier is observable (optional — `kubectl exec` into Redis if the demo cluster permits).

### Caveats

- The `unit: MINUTE` window is best for demo because it visibly resets within the test window. Production policies typically use longer units.
- If the agent identifier is in a JWT claim rather than a header, the `RateLimitConfig` needs `descriptors` referencing the claim. The default test uses a header for simplicity.
- **Policy attachment**: a `RateLimitConfig` resource on its own does not enforce. It must be referenced from an `EnterpriseAgentgatewayPolicy` that targets the route (or the `Gateway`) you want rate-limited. If the demo cluster does not have that wiring in place, the script will show all 15 requests returning 200 — meaning auth + routing work, but the rate-limit policy is not bound. To complete the test, apply something like:
  ```yaml
  apiVersion: enterprise.agentgateway.solo.io/v1alpha1
  kind: EnterpriseAgentgatewayPolicy
  metadata:
    name: poc-ratelimit-attach
    namespace: agentgateway-system
  spec:
    targetRefs:
    - kind: Gateway
      name: agentgateway-hub
    rateLimit:
      configRef:
        name: poc-ratelimit
  ```
  The 10/15 split should then appear immediately.

## What this phase deliberately does NOT cover

- **Schema validation of MCP responses** (was v1's L7-GR-02). Default behaviour; no test needed.
- **Graceful HTTP error translation** (was v1's L7-GR-04). Also default behaviour — when an upstream MCP server crashes, the gateway returns an MCP-formatted error. Not a sales claim worth a dedicated test.
- **Circuit breakers across upstream replicas.** Provided by the gateway by default; not customer-flagged.
