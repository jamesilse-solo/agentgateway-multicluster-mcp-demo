# Phase 2 — Bridging to Internal Remote MCP Server

Validates MESH-05 through MESH-07 on the Singtel POC clusters.

## Run

```bash
KUBE_CONTEXT=cluster1-singtel KUBE_CONTEXT2=cluster2-singtel ./Phase2/validate.sh
```

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| MESH-05 | Cross-Cluster/VPC Complexity (Federation) | Agent calls /mcp/remote; gateway routes to cluster2 via HBONE east-west GW transparently | None |
| MESH-06 | Safe Legacy Tool Integration (ServiceEntry) | A VM-hosted MCP server is registered as a mesh-internal service via `ServiceEntry` | ServiceEntry created + deleted (net zero) |
| MESH-07 | Lateral Movement Prevention (Zero-Trust VPC) | A `Sidecar` egress restriction blocks connections to non-registered IPs from the agent namespace | Sidecar created + deleted (net zero) |

## Prerequisites

| Component | Namespace | Check |
|-----------|-----------|-------|
| `cluster1-singtel` context | — | `kubectl config get-contexts cluster1-singtel` |
| `cluster2-singtel` context | — | `kubectl config get-contexts cluster2-singtel` |
| `mcp-route-remote` HTTPRoute | `agentgateway-system` (cluster1) | `kubectl --context cluster1-singtel -n agentgateway-system get httproute mcp-route-remote` |
| `mcp-backends-remote` AgentgatewayBackend | `agentgateway-system` (cluster1) | from `06-cross-cluster-mcp.sh` |
| mcp-server-everything | `agentgateway-system` (cluster2) | `kubectl --context cluster2-singtel -n agentgateway-system get pod -l app=mcp-server-everything` |
| east-west gateways | `istio-eastwest` (both clusters) | `kubectl --context cluster1-singtel -n istio-eastwest get svc` |
| netshoot pod | `debug` (cluster1) | `kubectl --context cluster1-singtel -n debug get pod -l app=netshoot` |

Run `06-cross-cluster-mcp.sh` before this script if cross-cluster routes are not yet configured.
