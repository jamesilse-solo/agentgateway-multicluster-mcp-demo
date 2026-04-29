# Control Plane — AgentRegistry, Agent Gateway & Ambient Mesh

Validates CP-02, CP-04, and CP-05 on the POC clusters.

## Run

```bash
KUBE_CONTEXT=cluster1 KUBE_CONTEXT2=cluster2 ./POC-Success-Criteria/Phase7-ControlPlane-Registry-and-Mesh/validate.sh
```

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| CP-02 | Central Registry & Health Checks | AgentRegistry catalog reflects live server health; unhealthy servers are excluded from L7 discovery | None |
| CP-04 | Super Admin Master Control | Super Admin account has global cluster-scoped visibility and control | None |
| CP-05 | OTEL Distributed Tracing | MCP `tools/call` emits a traceparent header; Jaeger shows a single span spanning both clusters | None |

## Prerequisites

| Component | Namespace | Check |
|-----------|-----------|-------|
| `cluster1` context | — | `kubectl config get-contexts cluster1` |
| `cluster2` context | — | `kubectl config get-contexts cluster2` |
| istiod | `istio-system` (cluster1) | `kubectl --context cluster1 -n istio-system get pod -l app=istiod` |
| ztunnel DaemonSet | `istio-system` (both clusters) | `kubectl --context cluster1 -n istio-system get ds ztunnel` |
| AgentRegistry | `agentregistry` | `kubectl --context cluster1 -n agentregistry get pod` |
| agentgateway-hub | `agentgateway-system` | `kubectl --context cluster1 -n agentgateway-system get svc agentgateway-hub` |
| OTEL collector (optional) | any | required for CP-05 trace capture |

**Note on CP-05:** Deploy the OTEL stack using `docs.solo.io/agentgateway/2.2.x/observability/otel-stack/` before running this test if distributed traces are not yet emitted.
