# Phase 4 — Egress & Data-Loss Prevention

> **Kubernetes Gateway API v1.4.0 (standard channel)** is required for EGR-01 (the egress `Gateway` + `HTTPRoute` that pins SaaS traffic through a single source IP). EGR-02 and EGR-03 use Istio's `AuthorizationPolicy` (`security.istio.io/v1`) and do not depend on Gateway API directly. See [`../README.md`](../README.md#kubernetes-gateway-api-requirements) for the full version + CRD matrix.

> Validates **EGR-01, EGR-02, EGR-03** — the controls that govern what an agent is allowed to send *out* of the cluster, and what happens when it tries to break those rules. This phase covers the **outbound** half of the security story; Phase 2 covers inbound (server-side) and Phase 5 covers identity/authorization.

The customer's question this phase answers: *"if a prompt-injected agent tries to exfiltrate data to an unapproved destination, what stops it?"*

The defense-in-depth answer:

- **EGR-01** — for *approved* outbound calls (e.g. SaaS MCP servers like Jira, Atlassian, Salesforce), the mesh's egress gateway provides a single, stable source IP so the SaaS vendor can apply a clean IP allowlist.
- **EGR-02** — for traffic to a *DLP-protected* destination, an `AuthorizationPolicy` evaluated by ztunnel drops the agent's TCP at L4 using its SPIFFE identity *before* the application sends data. This is the hard fail-safe for data exfiltration even when L7 guardrails miss.
- **EGR-03** — for an agent attempting *lateral movement* to a destination it's not authorised for, ztunnel applies the same destination-side `AuthorizationPolicy` and drops the connection.

## Tests in this phase

| ID | Requirement | What success proves | Net cluster change |
|----|-------------|---------------------|--------------------|
| EGR-01 | Centralized SaaS Egress (Egress Gateway) | All outbound calls to a registered SaaS MCP server appear with a single source IP — the egress gateway's. SaaS vendors can write IP allowlists. | None |
| EGR-02 | Data Exfiltration Cage (destination-side `AuthorizationPolicy`) | An agent attempting to reach a DLP-protected destination is dropped at L4 using its SPIFFE identity. No data leaves. | One `AuthorizationPolicy` applied and deleted (net zero) |
| EGR-03 | Lateral-Movement Prevention (Zero-Trust VPC) | An agent allowed to call its intended tool is simultaneously blocked from a lateral target by destination-side `AuthorizationPolicy`. | One `AuthorizationPolicy` applied and deleted (net zero) |

## Run

```bash
KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase4-Egress-and-DLP/validate.sh
```

The script is interactive. Both `AuthorizationPolicy` resources used in EGR-02 and EGR-03 are deleted before the next step.

## Prerequisites

| Component | Namespace | Why |
|-----------|-----------|-----|
| Egress gateway pod | `istio-system` (label `istio=egressgateway`) | EGR-01 routing target |
| `netshoot` debug pod | `debug` | request originator |
| `mcp-server-everything` | `agentgateway-system` | reachable in-cluster baseline for EGR-03 |
| A registered public MCP server | external | EGR-01 target — example: `search.solo.io/mcp` |

## EGR-01 — Centralized SaaS Egress

### What we're proving

When agents call public SaaS MCP servers (Atlassian, Salesforce, Jira, custom partner APIs), the SaaS provider needs a way to identify the originating organisation's traffic. Random pod IPs change per deployment and per scale-out — they can't be allowlisted at the partner. Routing all such egress through a dedicated **egress gateway** gives the SaaS provider a single source IP (the egress gateway's external IP), enabling clean IP allowlists.

### What the script does

1. List the egress gateway pods in `istio-system`. Confirm `Running`.
2. From `netshoot`, send a tools/list to a public MCP endpoint (`search.solo.io/mcp` is the default). Capture the source IP visible from the destination if possible.
3. Apply or confirm a Gateway API `Gateway` + `HTTPRoute` config that pins egress for that destination through the egress gateway, then re-run the call.

### What success looks like

- Egress gateway pods Running.
- The public MCP call succeeds.
- Source IP visible to the SaaS endpoint matches the egress gateway's external IP, not a pod IP. (If the destination doesn't echo source IP, the test relies on egress gateway access logs to prove the path.)

### Caveats

- This test depends on having an actual public MCP endpoint reachable from the cluster. `search.solo.io/mcp` is used by default; substitute as needed.
- The "single static IP" property requires a `LoadBalancer` (or `NodePort` with stable allocation) on the egress gateway. The default install uses a cloud LB; this is environment-specific.

## EGR-02 — Data Exfiltration Cage (destination-side AuthorizationPolicy)

### What we're proving

The hard-stop case: a prompt-injected agent should not be able to reach a protected destination it has not been explicitly authorised for. With `AuthorizationPolicy` in the ambient mesh, ztunnel evaluates the source pod's SPIFFE identity at the destination side and drops the TCP segment at L4 — the application never sees the connection.

This is layered with L7 guardrails (Phase 6 GR-01) and identity policies (Phase 5). The L4 drop is the **fail-safe** when those upper layers miss.

> **Note on `REGISTRY_ONLY`:** Istio's classic `outboundTrafficPolicy.mode: REGISTRY_ONLY` is a **mesh-wide MeshConfig setting** that affects every ambient-enrolled namespace. Changing it in a shared cluster is risky for a demo, so this test demonstrates the same principle (identity-bound L4 enforcement) using a destination-side `AuthorizationPolicy`. To enable true `REGISTRY_ONLY` for a production rollout, edit `meshConfig.outboundTrafficPolicy.mode` in the Istio install values.

### What the script does

1. **Baseline**: from `netshoot`, curl `mcp-server-everything` (representing a DLP-protected target). Expect a non-zero HTTP response (path is open).
2. Apply an `AuthorizationPolicy` in `agentgateway-system` with `action: DENY`, selector `app=mcp-server-everything`, source `namespaces: ["debug"]`.
3. Wait ~4 seconds for XDS propagation.
4. Re-run the curl. Expect HTTP `000` — ztunnel drops at L4 using the source SPIFFE identity.
5. Tail ztunnel logs and confirm the policy-rejection line.
6. Delete the `AuthorizationPolicy`.

### What success looks like

- Pre-policy: curl returns a real HTTP code (e.g. `404`).
- Post-policy: curl returns `000` (TCP dropped before HTTP).
- ztunnel log line includes `policy rejection: explicitly denied by: agentgateway-system/egr02-dlp-deny` and the source pod's SPIFFE URI.
- Cleanup leaves no `AuthorizationPolicy` behind.

### Caveats

- This test uses destination-side enforcement — meaning a policy must exist on each destination an agent should be blocked from. For broader "default-deny" semantics, combine namespace-wide ALLOW policies with a catch-all DENY (or use `REGISTRY_ONLY` at MeshConfig level).
- `AuthorizationPolicy` enforcement depends on both source and destination namespaces being ambient-enrolled. Verify with `kubectl get ns --show-labels | grep dataplane-mode`.

## EGR-03 — Lateral-Movement Prevention

### What we're proving

A compromised agent can be told to scan the VPC: try every private IP, every neighbouring pod, every database service it can reach. With pod-IP-based firewalls, those scans often succeed because the agent has a legitimate cluster IP.

With the ambient mesh, lateral movement is bounded by **what the agent's identity is authorised to reach at each destination**, not what its IP can route to. `AuthorizationPolicy` resources applied per-destination, evaluated by ztunnel using SPIFFE identity, constrain the blast radius.

This test demonstrates the principle by allowing the agent to reach one destination (the legitimate tool target) while blocking it from another (a "pivot" target).

### What the script does

1. **Baseline**: from `netshoot`, curl two destinations:
   - `mcp-server-everything` — the intended tool target (no policy → allowed)
   - `agentregistry-agentregistry-enterprise` (in `agentregistry` namespace) — a representative "lateral" target
2. Apply an `AuthorizationPolicy` in `agentregistry` with `action: DENY`, selector for the registry, source `namespaces: ["debug"]`.
3. Wait ~4 seconds for XDS propagation.
4. Re-run both curls. Expect:
   - mcp-server-everything: same HTTP code as before (still allowed — no policy applied).
   - agentregistry: HTTP `000` (newly blocked).
5. Delete the `AuthorizationPolicy`.

### What success looks like

- Allowed destination keeps returning a real HTTP code throughout.
- Lateral destination returns `000` after the policy is applied.
- Cleanup removes the policy.

## What this phase deliberately does NOT cover

- **L7 content inspection on egress.** Whether the body of an outbound call contains PII or secrets is an L7 guardrails concern (Phase 6, GR-01). This phase is L4 / network-layer only.
- **Outbound mTLS to upstream services.** Whether the agent's outbound TLS uses an mTLS identity to the SaaS endpoint is part of upstream-auth (a separate concern, on the roadmap).
- **DNS exfiltration.** A truly determined attacker can sometimes exfiltrate via DNS query patterns even when REGISTRY_ONLY is in place. A separate DNS-monitoring control is needed for that — not validated here.
