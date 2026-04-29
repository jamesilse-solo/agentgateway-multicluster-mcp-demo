# Phase 3 — Securing the Internet (Public MCP Servers)

Validates MESH-08 and MESH-09 on the Singtel POC clusters.

## Run

```bash
KUBE_CONTEXT=cluster1-singtel ./Phase3/validate.sh
```

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| MESH-08 | Centralized SaaS Egress (Egress Gateway) | All outbound agent traffic exits via a single static LB IP; SaaS vendors need only one IP allowlist entry | None (egress gateway must already be deployed) |
| MESH-09 | Data Exfiltration Cage (REGISTRY_ONLY) | A `Sidecar` egress restriction blocks POST to unregistered external URLs; prompt-injection exfiltration is dropped at L4 | Sidecar created + deleted (net zero) |

## Prerequisites

| Component | Namespace | Check |
|-----------|-----------|-------|
| `cluster1-singtel` context | — | `kubectl config get-contexts cluster1-singtel` |
| netshoot pod | `debug` | `kubectl --context cluster1-singtel -n debug get pod -l app=netshoot` |
| Egress gateway | `istio-system` | `kubectl --context cluster1-singtel -n istio-system get pod -l istio=egressgateway` |
| mcp-server-everything | `agentgateway-system` | for MESH-09 baseline traffic test |

MESH-08 requires a deployed egress gateway. If one is not present, the script will display instructions on how to enable it and will document what the behavior would be.
