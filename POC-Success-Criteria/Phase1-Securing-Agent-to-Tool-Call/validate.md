# Phase 1 — Securing Agent to Tool Call

Validates MESH-01 through MESH-04 on the Singtel POC clusters using the interactive script `validate.sh`.

## Run

```bash
KUBE_CONTEXT=cluster1-singtel ./POC-Success-Criteria/Phase1-Securing-Agent-to-Tool-Call/validate.sh
```

The script is interactive — press **Enter** at each step to advance. No persistent changes are made to the cluster (MESH-02 applies an `AuthorizationPolicy` and deletes it within the same run).

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| MESH-01 | Zero-Friction Tool Onboarding (Sidecar-less) | A single namespace label enrolls pods into ztunnel mTLS — no proxy injection, no code changes | None |
| MESH-02 | Agent-Specific Trust Boundaries (L4 Isolation) | `AuthorizationPolicy DENY` drops the agent's TCP connection using SPIFFE identity | Policy created + deleted (net zero) |
| MESH-03 | Protecting Agent Reasoning State (Session Resumability) | Active streaming MCP session survives a ztunnel DaemonSet rolling restart | DaemonSet restart (self-heals) |
| MESH-04 | Handling Heavy AI Data Payloads (MTU Limits) | ztunnel HBONE tunnel forwards a >10 MB JSON-RPC payload without truncation | None |

## Prerequisites

| Component | Namespace | Verification command |
|-----------|-----------|----------------------|
| `cluster1-singtel` kubeconfig context | — | `kubectl config get-contexts cluster1-singtel` |
| ztunnel DaemonSet | `istio-system` | `kubectl --context cluster1-singtel -n istio-system get ds ztunnel` |
| mcp-server-everything Deployment + Service | `agentgateway-system` | `kubectl --context cluster1-singtel -n agentgateway-system get deploy,svc mcp-server-everything` |
| netshoot debug pod | `debug` | `kubectl --context cluster1-singtel -n debug get pod -l app=netshoot` |
| `agentgateway-system` ambient label | — | `kubectl --context cluster1-singtel get ns agentgateway-system --show-labels \| grep dataplane-mode` |

MESH-03 requires two terminal windows open simultaneously (instructions are printed by the script at the relevant step).
