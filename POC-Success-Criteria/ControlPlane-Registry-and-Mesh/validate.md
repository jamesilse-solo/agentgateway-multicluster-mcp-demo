# Control Plane — AgentRegistry, Agent Gateway & Ambient Mesh

Validates CP-01 through CP-05 on the Singtel POC clusters.

## Run

```bash
KUBE_CONTEXT=cluster1-singtel KUBE_CONTEXT2=cluster2-singtel ./POC-Success-Criteria/ControlPlane-Registry-and-Mesh/validate.sh
```

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| CP-01 | Hybrid / Single Control Plane | istiod (cluster1) pushes xDS to ztunnel on both clusters; AGW control plane manages both data planes | None |
| CP-02 | Central Registry & Health Checks | AgentRegistry catalog reflects live server health; unhealthy servers are excluded from L7 discovery | None |
| CP-03 | Isolated Admin Workspaces | Workspace CRDs + RBAC limit admin visibility to their namespace boundary | None |
| CP-04 | Super Admin Master Control | Super Admin account has global cluster-scoped visibility and control | None |
| CP-05 | OTEL Distributed Tracing | MCP `tools/call` emits a traceparent header; Jaeger shows a single span spanning both clusters | None |

## Prerequisites

| Component | Namespace | Check |
|-----------|-----------|-------|
| `cluster1-singtel` context | — | `kubectl config get-contexts cluster1-singtel` |
| `cluster2-singtel` context | — | `kubectl config get-contexts cluster2-singtel` |
| istiod | `istio-system` (cluster1) | `kubectl --context cluster1-singtel -n istio-system get pod -l app=istiod` |
| ztunnel DaemonSet | `istio-system` (both clusters) | `kubectl --context cluster1-singtel -n istio-system get ds ztunnel` |
| AgentRegistry | `agentregistry` | `kubectl --context cluster1-singtel -n agentregistry get pod` |
| agentgateway-hub | `agentgateway-system` | `kubectl --context cluster1-singtel -n agentgateway-system get svc agentgateway-hub` |
| OTEL collector (optional) | any | required for CP-05 trace capture |

**Note on CP-03:** Workspace CRDs require Gloo Mesh Enterprise management plane. If not deployed, the script documents the expected configuration pattern and what the isolation boundary would look like.

**Note on CP-05:** Deploy the OTEL stack using `docs.solo.io/agentgateway/2.2.x/observability/otel-stack/` before running this test if distributed traces are not yet emitted.
