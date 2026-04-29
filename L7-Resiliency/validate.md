# L7 Agent Gateway — Resiliency & External Guardrails

Validates L7-GR-01 through L7-GR-04 on the Singtel POC clusters.

## Run

```bash
KUBE_CONTEXT=cluster1-singtel ./L7-Resiliency/validate.sh
```

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| L7-GR-01 | External Guardrails Webhooks | ExtProc streams JSON-RPC payload to a webhook; webhook sanitizes PII; Envoy forwards clean payload | None |
| L7-GR-02 | Schema Validation | Gateway validates JSON-RPC response structure; malformed responses replaced with MCP-compliant errors | None |
| L7-GR-03 | Rate Limiting & Circuit Breakers | RateLimitConfig caps requests/min; requests above threshold return HTTP 429 | None |
| L7-GR-04 | Graceful HTTP Error Translation | Backend MCP server scaled to 0; gateway returns a valid JSON-RPC error (not raw 502) | Deploy scale to 0, then restore (net zero) |

## Prerequisites

| Component | Namespace | Check |
|-----------|-----------|-------|
| `cluster1-singtel` context | — | `kubectl config get-contexts cluster1-singtel` |
| agentgateway-hub service | `agentgateway-system` | `kubectl --context cluster1-singtel -n agentgateway-system get svc agentgateway-hub` |
| mcp-server-everything | `agentgateway-system` | must be Running (L7-GR-04 scales it down then restores) |
| netshoot pod | `debug` | used for in-cluster curl tests |
| Redis (ext-cache) | `agentgateway-system` | required for L7-GR-03 — `kubectl --context cluster1-singtel -n agentgateway-system get pod -l app=ext-cache` |

**Note on L7-GR-01:** A guardrail webhook endpoint (e.g. F5 Calypso) is required for full validation. The script shows the configuration pattern and what the expected response headers look like.
