# POC Success Criteria — v2

> Streamlined from v1 (29 tests across 7 phases) to **20 tests across 7 phases**, reordered so the **MCP Server Lifecycle** flow opens the validation set. Architecture language matches the customer-facing **distributed MCP Gateway mesh** model. The v1 phase tree has been preserved as `../POC-Success-Criteria-template/` (customer references stripped) for reference and reuse on future engagements.

## Why v2 exists

v1 was correct but heavy: 29 tests, several duplicates, and the most-asked-for flow — **register an MCP server → propagate to the gateway → call it from an agent** — was not in the list at all. v2 fixes both problems:

- The lifecycle flow is now **Phase 1**.
- Tests that overlapped, restated default behaviour, or were tangential to the customer's stated workloads were dropped (13 in total).
- Four new tests were added to cover gaps surfaced in customer syncs: **two-level tool filtering**, **token exchange / on-behalf-of**, **per-model token usage observability**, plus the lifecycle phase.
- Phase numbering was reorganised so **Identity** sits with **Access Control** (Phase 5) and **Egress / DLP** is its own dedicated phase (Phase 4).

The full diff is documented in the change-log section of the customer-facing markdown (`POC-Success-Criteria-v2.md` in the customer wiki).

## Kubernetes Gateway API requirements

These tests assume the **Kubernetes Gateway API v1.4.0 standard channel** is installed cluster-wide. Earlier versions (≥ v1.0.0) work for most resources but may miss features used in Phase 4 (egress gateway BackendTLSPolicy patterns) and Phase 3 (composite backend routing).

```bash
# Default install used by scripts/01-install.sh:
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

| Resource | API group | Used in |
|----------|-----------|---------|
| `Gateway`, `HTTPRoute`, `GatewayClass` | `gateway.networking.k8s.io/v1` | Phase 1, Phase 3, Phase 4 |
| `AgentgatewayBackend` | `agentgateway.dev/v1alpha1` (Solo CRD) | Phase 1, Phase 3 |
| `EnterpriseAgentgatewayParameters` | `enterpriseagentgateway.solo.io/v1alpha1` (Solo CRD) | Phase 7 (config), referenced by GatewayClass |
| `EnterpriseAgentgatewayPolicy` | `enterprise.agentgateway.solo.io/v1alpha1` (Solo CRD) | Phase 6 (policy attachment) |
| `RateLimitConfig` | `ratelimit.solo.io/v1alpha1` (Solo CRD) | Phase 6 |
| `AuthConfig` | Solo ExtAuth CRD | Phase 5 |
| `AuthorizationPolicy` | `security.istio.io/v1` (Istio) | Phase 2, Phase 4 |

If the GatewayClass `enterprise-agentgateway` is missing, no `Gateway` will program. Verify with:
```bash
kubectl --context cluster1 get gatewayclass enterprise-agentgateway -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}{"\n"}'
# Expected: True
```

## Layout

Each phase directory contains:

- `validate.md` — verbose human-readable doc. Explains what each test proves, how the script executes it, what success looks like, prerequisites, and caveats. **Read this first.**
- `validate.sh` — interactive shell script. Thin orchestrator — prints banners, runs `kubectl` commands, pauses between steps. The narrative lives in `validate.md`.

| Phase | Directory | Tests |
|-------|-----------|-------|
| 1 | [Phase1-MCP-Server-Lifecycle](Phase1-MCP-Server-Lifecycle/) | CR-01, CR-02, CR-03 |
| 2 | [Phase2-Securing-Tool-Calls](Phase2-Securing-Tool-Calls/) | MESH-01, MESH-02, MESH-03 |
| 3 | [Phase3-Federated-MCP-Mesh](Phase3-Federated-MCP-Mesh/) | FED-01, FED-02, FED-03 |
| 4 | [Phase4-Egress-and-DLP](Phase4-Egress-and-DLP/) | EGR-01, EGR-02, EGR-03 |
| 5 | [Phase5-Identity-and-Access](Phase5-Identity-and-Access/) | AUTH-01, AUTH-02, AUTH-03, AUTH-04 |
| 6 | [Phase6-Resiliency-and-Guardrails](Phase6-Resiliency-and-Guardrails/) | GR-01, GR-02 |
| 7 | [Phase7-Observability](Phase7-Observability/) | OBS-01, OBS-02 |

## Run any phase

```bash
KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/PhaseN-<name>/validate.sh
# Phase 3 federation also takes:
# KUBE_CONTEXT2=cluster2  ./POC-Success-Criteria-v2/Phase3-Federated-MCP-Mesh/validate.sh
```

All scripts are interactive — press **Enter** at each step. None apply persistent changes; resources created mid-test (an `AuthorizationPolicy`, a `RateLimitConfig`, etc.) are deleted before the next step.

## Definitions

- **MCP Gateway** — AgentGateway data plane. Customer-facing terminology to avoid "agents" in EA-audience material.
- **Distributed MCP Gateway mesh** — every environment runs its own MCP Gateway; environments are joined via HBONE tunnels (ports 15008 + 15012). Not hub-and-spoke.
- **Agent Registry** — the catalog of approved MCP servers. Discovery API: `GET /v0/servers?search=<name>`. Today the path from registry to MCP Gateway is a shell-script bridge; native propagation is on the product roadmap.
- **HBONE** — HTTP-based Overlay Network Environment. Istio ambient's L4 mTLS overlay carrying inter-pod and inter-cluster traffic; uses ports 15008 (mTLS) and 15012 (control).
