# Phase 2 — Securing Agent-to-Tool Calls

> Validates **MESH-01, MESH-02, MESH-03** — the security and resilience properties that the **ambient mesh** brings to every MCP call inside a single environment. This phase is the bedrock: if these don't hold, nothing in Phases 3-7 matters, because every higher-layer guarantee (federation, identity, rate-limiting) is built on top.

This phase consolidates v1's MESH-01 through MESH-04. Heavy-payload behaviour (formerly MESH-04) is now merged into MESH-03 because it tests the same property — *the HBONE tunnel handles real-world traffic shapes without breaking the agent's session*.

## What this phase proves

The customer's ask, in their own words: *"AI agents need to call internal MCP servers. We don't want to make every tool team write proxy config, write auth code, or change how their app handles the network."*

The ambient mesh delivers that with three properties:

1. **Onboarding is a label, not a code change.** Tag a namespace with `istio.io/dataplane-mode=ambient` and every pod in it is enrolled in the mesh — mTLS, identity, observability — automatically. No application change required.
2. **Authorization is enforced at L4 using cryptographic identity.** A pod's SPIFFE identity (e.g. `spiffe://cluster.local/ns/debug/sa/default`) is the policy subject. Denied connections are dropped at TCP — the application never sees the request — using the source pod's identity, not its IP.
3. **Maintenance and large payloads do not break agents.** Restarting the data-plane component (`ztunnel`) preserves in-flight TCP sessions because TCP state lives in the kernel, not in the ztunnel pod. The HBONE tunnel handles oversized payloads (10MB+) without truncation or reset.

## Tests in this phase

| ID | Requirement | What success proves | Net cluster change |
|----|-------------|---------------------|--------------------|
| MESH-01 | Zero-Friction Tool Onboarding | One namespace label is sufficient to enrol an MCP server in the ambient mesh — no proxy container, no code changes | None |
| MESH-02 | Agent-Specific Trust Boundaries (L4 Isolation) | A DENY `AuthorizationPolicy` drops the agent's TCP at L4 using its SPIFFE identity; the MCP server never sees the request | One `AuthorizationPolicy` created and deleted within the run (net zero) |
| MESH-03 | Resilient Long-Running Sessions | A streaming MCP session survives a ztunnel rolling restart **and** correctly forwards a >10MB payload through the HBONE tunnel | DaemonSet restart (self-heals) |

## Run

```bash
KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase2-Securing-Tool-Calls/validate.sh
```

The script is interactive — press **Enter** at each step. **MESH-03 requires two terminals** (instructions printed inline at the relevant step).

## Prerequisites

| Component | Namespace | Verification |
|-----------|-----------|--------------|
| `cluster1` kubeconfig context | — | `kubectl config get-contexts cluster1` |
| Ambient label on `agentgateway-system` | — | `kubectl --context cluster1 get ns agentgateway-system --show-labels \| grep dataplane-mode` |
| ztunnel DaemonSet | `istio-system` | `kubectl --context cluster1 -n istio-system get ds ztunnel` |
| `mcp-server-everything` Deployment + Service | `agentgateway-system` | `kubectl --context cluster1 -n agentgateway-system get deploy,svc mcp-server-everything` |
| `netshoot` debug pod | `debug` | `kubectl --context cluster1 -n debug get pod -l app=netshoot` |

## MESH-01 — Zero-Friction Tool Onboarding

### What we're proving

The MCP developer should not have to know the mesh exists. A team building an MCP server writes `Deployment` + `Service` YAML, ships it, and the platform team's mesh policies apply automatically. The ambient data plane runs as a per-node `ztunnel` DaemonSet that intercepts TCP at the kernel level, so the application pod is unchanged — same containers, same image, same readiness probes.

### What the script does

1. Confirms `agentgateway-system` carries `istio.io/dataplane-mode=ambient`. This is the *only* change required to enrol every pod in the namespace.
2. Inspects the `mcp-server-everything` pod and confirms its container set is exactly the workload's containers — no proxy container is added.
3. Lists the `ztunnel` DaemonSet and confirms one pod per node, all `Running`.
4. From `netshoot`, sends a `curl` to `mcp-server-everything`. Then tails ztunnel access logs and shows the SPIFFE identities (`src.identity` / `dst.identity`) on the connection.

### What success looks like

- Single label visible on the namespace.
- The MCP server pod's container list matches the application's `Deployment` spec — no extra containers.
- All ztunnel pods `Running`.
- ztunnel access log entry for the curl, showing SPIFFE source/destination — confirming mTLS was applied transparently with no application-layer change.

### Caveats

- If ztunnel access logs are quiet for a few seconds, the test re-runs the curl. Logs are best-effort tails — the *presence* of the ztunnel DaemonSet plus the HTTP response together is the proof, not the log line itself.

## MESH-02 — Agent-Specific Trust Boundaries (L4 Isolation)

### What we're proving

When an agent gets compromised (prompt injection, leaked token, malicious tool result), the blast radius must stop at the agent's identity. Network-layer firewall rules don't help — the agent has a legitimate IP. **What stops it is a cryptographic identity at L4**: ztunnel checks the source pod's SPIFFE identity against an `AuthorizationPolicy` and decides whether to forward the TCP segment at all. The MCP server never sees a denied request.

This matters more for AI agents than for traditional services because agents can be tricked into connecting to internal addresses they have no business reaching, by inputs they themselves don't control.

### What the script does

1. **Baseline**: from `netshoot` (running in `debug` namespace, simulating "the agent"), curl `mcp-server-everything`. Expect a non-zero HTTP code — the path is open.
2. Apply an `AuthorizationPolicy` in `agentgateway-system` with `action: DENY`, selector `app=mcp-server-everything`, source `namespaces: ["debug"]`.
3. Wait ~4 seconds for istiod to push the policy via XDS to ztunnel.
4. **After**: re-run the same curl. Expect HTTP `000` — ztunnel drops the connection at L4. Inspect ztunnel logs for the policy-rejection line showing the SPIFFE source.
5. Delete the policy. The cluster ends in the same state.

### What success looks like

- Pre-policy curl returns a real HTTP code (e.g. `200`, `400`, anything).
- Post-policy curl returns `000` (connection refused/closed).
- ztunnel log line includes a SPIFFE URI in `src.identity` — confirming the deny decision used cryptographic identity, not IP.
- Cleanup leaves no `AuthorizationPolicy` behind.

### Caveats

- XDS propagation can take up to ~5 seconds on a busy cluster; the script sleeps 4s before retesting.
- If the cluster has additional cluster-wide DENY policies, this test still works — the test policy is namespace-scoped and additive.

## MESH-03 — Resilient Long-Running Sessions

### What we're proving

Two failure modes that, in classical proxy-based systems, would terminate an in-flight agent session — and which ambient mesh handles transparently:

1. **Data-plane upgrades / rotations.** When ztunnel pods are replaced (rolling restart, version upgrade, node replacement), in-flight TCP sessions established through them must not break. If they did, an AI agent in the middle of a long reasoning chain would lose its context window mid-thought.
2. **Oversized payloads.** AI tools routinely shuttle multi-megabyte JSON blobs (large context windows, multimodal data, embeddings). The HBONE tunnel must fragment, transmit, and reassemble these without mid-stream resets.

The first holds because **TCP socket state lives in the Linux kernel netfilter layer, not in the ztunnel pod process**. ztunnel restarts; the kernel's connection tracking does not. The HBONE tunnel re-establishes per-node and the upper-layer stream resumes.

The second holds because HBONE is a standard TCP-over-mTLS overlay; large payloads fragment normally at the IP layer.

### What the script does

#### Part A: ztunnel rolling restart (two terminals)

1. Print the exact `kubectl exec ... curl -N` command for **Terminal 1** to run, opening a long-lived `/sse` streaming connection from `netshoot` to `mcp-server-everything`. Reviewer copies this to a separate terminal and leaves it running.
2. Reviewer presses Enter in **Terminal 2 (the script)**. The script runs `kubectl rollout restart daemonset/ztunnel` and waits for the rollout to complete (~30-60 seconds; one ztunnel pod per node is replaced one at a time).
3. Reviewer switches back to Terminal 1. The curl stream should still be running — no broken pipe, no disconnect.

#### Part B: heavy payload through the HBONE tunnel

1. Inside `netshoot`, `dd if=/dev/urandom bs=1M count=12 | base64 | tr -d '\n'` produces ~16MB of base64 ASCII.
2. Wrap it in a JSON-RPC `tools/list` body as a padding field, write it to a file.
3. `curl -X POST --data-binary @file http://mcp-server-everything/` — POST through the ambient mesh.
4. `curl -w '%{size_upload}'` reports actual bytes uploaded. Tail ztunnel logs for the connection's `bytes_recv` value.

### What success looks like

- **Part A**: Terminal 1's stream survives the rolling restart. Terminal 2 shows `ztunnel rolled successfully`.
- **Part B**: `size_upload` exceeds 10,000,000 bytes; ztunnel log entry for the connection shows a matching `bytes_recv` value; some HTTP response (200, 400, 405 — the server may reject a malformed body, that's acceptable; the test is about delivery, not parseability).

### Caveats

- Part A relies on the streaming endpoint (`/sse`) staying open. If `mcp-server-everything` does not expose `/sse`, swap to `/mcp` with a long-lived initialise request. Behaviour is the same — TCP survives the ztunnel cycle.
- Part B's HTTP code may vary depending on how the MCP server reacts to a body it cannot parse. The script tolerates any response — what matters is that bytes traversed the tunnel.

## Cleanup summary

| Step | Cleanup |
|------|---------|
| MESH-01 | None |
| MESH-02 | `AuthorizationPolicy demo-deny-netshoot` deleted at end of step |
| MESH-03 | None (rolling restart self-heals; tmp files inside netshoot are removed by the inline script) |

## What this phase deliberately does NOT cover

- **L7 policies (header-, claim-, or method-based authorization).** Phase 5 covers OAuth/OIDC at the gateway and OPA-driven tool RBAC. The mesh's job stops at L4 identity.
- **Rate limiting and ext-proc guardrails.** Those are gateway-layer concerns; see Phase 6.
- **Cross-cluster traffic.** Phase 3 handles federation. This phase stays in a single cluster on purpose — to isolate the mesh's contribution from the gateway's contribution.
