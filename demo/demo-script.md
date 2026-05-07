# Solo.io AgentGateway — 35-Minute Demo Script

**Audience:** Enterprise architects  
**Presenter:** SE team  
**Duration:** 35 minutes  
**Core messages:** (1) Centralized MCP gateway + registry, (2) Auth enforcement at the platform layer, (3) Bidirectional cross-cluster federation

---

## Pre-Demo Checklist (T-15 min)

Run these before the call starts. Everything should be green before screen-share.

```bash
# 1. Start all port-forwards (leave this running in a dedicated terminal)
KUBE_CONTEXT=cluster1 ./demo/portforward.sh
# → All five sections should show ✓ (AgentRegistry / AGW UI / Gloo Mesh / Dex / MCP LBs)

# 2. Verify AgentRegistry UI loads and shows 3 servers
open http://localhost:8080
# → Log in with any credentials (demo auth). Navigate to Servers — confirm 3 entries.

# 3. Verify AgentGateway Enterprise UI loads
open http://localhost:4000
# → Should show Routes, Backends, Policies in the left nav.

# 4. Verify Gloo Mesh UI loads
open http://localhost:8090
# → Should show cluster topology with cluster1 and cluster2 registered.

# 5. Confirm both AGW LBs resolve
kubectl --context cluster1 -n agentgateway-system get svc agentgateway-hub
kubectl --context cluster2 -n agentgateway-system get svc agentgateway-spoke
# → Copy both EXTERNAL-IP / hostnames for reference

# 6. Verify cluster1 → cluster2 MCP works
./demo/send-traffic.sh --remote
# → Should complete with tool list and echo response from cluster2

# 7. Verify cluster2 → cluster1 MCP works
C2_LB=$(kubectl --context cluster2 -n agentgateway-system \
  get svc agentgateway-spoke -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
AGW_LB="${C2_LB}" ./demo/send-traffic.sh --remote
# → Tool list and echo response from cluster1 via cluster2's gateway

# 8. Open demo-deck.html in browser, navigate to slide 1
open ./demo/demo-deck.html
```

Have four browser tabs open: AgentRegistry UI (8080), AgentGateway Enterprise UI (4000), Gloo Mesh UI (8090), demo deck.  
Have two terminal tabs ready: portforward.sh (running), demo traffic commands.

---

## Segment 0 — Architecture Context (4 min)

**Show:** `demo/demo-deck.html` — slides 1 and 2  
**Goal:** Frame the problem and the two core concepts before any live demo.

**Slide 1 — Title**

> "What we've deployed here is a complete federated AI agent infrastructure across your two EKS clusters. Today we'll show two things: how you centralize and govern all MCP tool traffic through a single gateway and registry — and how that gateway transparently federates calls across clusters in both directions, so agents never need to know or care which cluster a tool lives on."

**Slide 2 — Architecture**

> "Two EKS clusters. Each runs AgentGateway Enterprise — the single policy enforcement point for every MCP call. Cluster 1 also runs AgentRegistry, which is your MCP service catalog."

> "AgentRegistry is what agents use to discover tools by name rather than by hardcoded URL. A call to `/v0/servers?search=com.amazonaws` returns everything the agent needs to connect."

> "The two clusters are connected over HBONE mutual TLS — that's the blue line at the bottom, handled by the ambient mesh. An agent on cluster 1 can reach tools on cluster 2, and vice versa. The routing is path-based and completely transparent to the agent. We'll demonstrate both directions."

**Transition:**

> "Let's start with the registry."

---

## Segment 1 — AgentRegistry (5 min)

**Show:** Browser tab with `http://localhost:8080`  
**Goal:** Show the catalog, walk through an entry, demonstrate the discovery workflow.

**Open the Servers tab**

> "This is the AgentRegistry Enterprise UI. Three servers are already registered — the two internal MCP servers on cluster 1 and cluster 2, plus the Solo.io documentation search server."

**Click on `com.amazonaws/mcp-everything-local`**

> "The naming follows reverse-domain convention. `com.amazonaws` maps to amazonaws.com — which is where the AgentGateway load balancer lives. The registry validates that the URL you register matches the namespace, so teams can't squatting on each other's namespace."

> "The entry has the URL, a JSON schema reference, version, and title. Any agent does a GET to `/v0/servers?search=com.amazonaws` and gets back everything it needs to open an MCP session — no hardcoded URLs, no out-of-band configuration."

**Register a new server live**

```bash
curl -s -X POST http://localhost:8080/v0/servers \
  -H "Content-Type: application/json" \
  -d '{
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-10-17/server.schema.json",
    "name": "com.amazonaws/mcp-demo-live",
    "title": "Live Demo Server",
    "version": "1.0.0",
    "remotes": [{"type": "streamable-http", "url": "http://'"${AGW_LB:-agw-lb}"'/mcp"}]
  }' | python3 -m json.tool
```

> "One API call. No restart, no config change. In production this goes into your CI/CD pipeline — a new tool server registers itself at deploy time."

---

## Segment 2 — Agent Traffic + Auth Flow (6 min)

**Show:** Slide 3 (Auth Flow), then terminal running `send-traffic.sh`  
**Goal:** Show the auth model on the slide, then demonstrate it live.

**Slide 3 — Auth Flow**

> "Before we run traffic, let me show you the security model. Two flows."

> "On the left: agent authentication. The agent acquires a JWT from the OIDC provider — in this case Dex, in production this is your enterprise IdP. That JWT is presented as a Bearer token on every MCP request. ExtAuth at the gateway validates the signature, expiry, and issuer on every call — not just session initialization. An expired or tampered token gets a 401 before it ever reaches a tool server."

> "On the right: the MCP session flow. Initialize gives you a session ID. tools/list and tools/call both carry the session ID and the Bearer token. The gateway enforces auth at every step. The MCP server has zero auth logic — all of it is at the gateway."

**Run send-traffic.sh**

```bash
KUBE_CONTEXT=cluster1 ./demo/send-traffic.sh
```

> "Step 1: JWT from Dex. In production this is a service account credential or OAuth client credentials flow."

> "Step 2: MCP session init. Bearer token on the POST. ExtAuth validates. We get back a session ID."

> "Step 3: tools/list — authenticated, routed, the tools come back."

> "Step 4: tools/call. Calling `echo` — full round trip through an authenticated, rate-limited, observable gateway."

---

## Segment 3 — AgentGateway Enterprise UI — Governance (6 min)

**Show:** Browser tab with `http://localhost:4000`  
**Goal:** Show the gateway control-plane — routes, backends, auth policy, traffic logs.

> "This is the AgentGateway Enterprise UI — the control plane for every MCP call flowing through the gateway. It shows the routes, the backends they point to, the authentication policies, rate limits, and the traffic that has passed through."

Navigate to Routes:

> "Here are the three routes configured on this gateway. `/mcp` routes to the local MCP server on cluster 1. `/mcp/remote` routes cross-cluster to cluster 2 via the HBONE tunnel. `/mcp/registry` routes to AgentRegistry — that's how agents discover available tools. Every one of these is configured as a Kubernetes HTTPRoute object. Infrastructure as code, version-controlled, reviewed."

Navigate to Backends:

> "Backends are the targets behind those routes — the actual service endpoints. Each backend has health status. You can see the AgentRegistry backend, both MCP server backends, and the cross-cluster backend for cluster 2."

Navigate to Policies / Auth:

> "This is the authentication policy. JWT validation via ExtAuth — the token issuer, the required claims, the allowed audiences. Every request that doesn't carry a valid token is rejected here, before it ever reaches a tool server. The MCP servers themselves have zero auth logic."

Navigate to Traffic / Logs:

> "The traffic we just sent from the terminal is here. Each MCP call — initialize, tools/list, tools/call — logged with the path, response code, latency, and the JWT identity. This is your audit trail. You can answer 'which agent called which tool at what time with what identity' for any call in the platform."

---

## Segment 4 — Gloo Mesh Enterprise UI — Multi-Cluster View (5 min)

**Show:** Browser tab with `http://localhost:8090`  
**Goal:** Show the cross-cluster topology and ambient mesh state.

> "Now let's look at the infrastructure layer. This is the Gloo Mesh Enterprise UI — it shows the full multi-cluster topology that the gateways and ambient mesh are running on."

Navigate to cluster overview:

> "Both clusters are registered here. Cluster 1 and cluster 2. You can see the AgentGateway data planes, the ambient mesh workloads, and the connection state between clusters."

Navigate to graph/topology if available:

> "This is the federation view. The east-west gateways on both clusters are the endpoints for the HBONE mTLS tunnel. Every cross-cluster MCP call traverses this path with cryptographic identity — no IP-based trust, no network-layer firewall rules. The mesh provides SPIFFE/SVID workload identity automatically."

> "The Gloo Mesh management plane is what keeps these two clusters in sync — workload discovery, service entries, and the XDS configuration that tells ztunnel on each cluster where to find workloads on the other. You can manage both clusters from a single control point."

---

## Segment 5 — Bidirectional Cross-Cluster Federation (7 min)

**Show:** Terminal, then Gloo Mesh UI  
**Goal:** Demonstrate MCP calls in both directions across clusters.

**Direction 1: Cluster 1 → Cluster 2**

```bash
KUBE_CONTEXT=cluster1 ./demo/send-traffic.sh --remote
```

> "Same gateway LB on cluster 1 — but the `/mcp/remote` path routes the call to cluster 2. Same JWT, same session flow. Watch — the tools come back from the cluster 2 MCP server."

After it succeeds:

> "That call traveled: cluster 1 AgentGateway → east-west gateway → HBONE mTLS → cluster 2 east-west gateway → cluster 2 mcp-server-everything. The agent called one URL and got back a response from a different cluster. Completely transparent."

**Direction 2: Cluster 2 → Cluster 1**

```bash
C2_LB=$(kubectl --context cluster2 -n agentgateway-system \
  get svc agentgateway-spoke -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
AGW_LB="${C2_LB}" ./demo/send-traffic.sh --remote
```

> "Now we're calling cluster 2's gateway at `/mcp/remote`. Watch — this time the call travels the other direction: cluster 2 AgentGateway routes to cluster 1's MCP server. Same `/mcp/remote` path convention, same auth model, same response."

> "Federation is bidirectional. An agent running on either cluster can reach tools on any cluster using the same path. You don't need separate gateway configurations or separate credentials per cluster."

Navigate to Gloo Mesh UI, show the traffic:

> "And here in the mesh topology you can see the traffic on both sides. Both east-west gateways are active. Both tunnels lit up."

**Key message:**

> "When you add a third cluster — another region, another on-prem location — you register it in Gloo Mesh, deploy an AgentGateway, add an HTTPRoute, and your existing agents can reach it immediately. No agent code changes. No new credentials to distribute. The platform handles all of it."

---

## Segment 6 — Q&A (2 min)

**Show:** Slide 6 (Federation) as backdrop  
**Goal:** Invite questions. Have these prompts ready if the room is silent.

- "What's your current approach for controlling which agents can call which tools? Is that enforced at the platform layer or inside each tool server?"

- "Does this federation model match how your BU separation works — different BUs owning different clusters or namespaces?"

- "How important is the audit trail for compliance — being able to say 'agent X called tool Y at time Z with this identity'?"

- "You mentioned AI agents running in multiple environments. How are those agents currently provisioned with credentials to call external services?"

---

## Key Messages Reference

| Segment | Core message |
|---------|-------------|
| Architecture | Two clusters, one governance model. Every AI agent finds its tools through the registry and calls them through the gateway. Traffic never bypasses policy. |
| Registry | MCP service catalog. Agents use names, not URLs. New tools register once and are immediately discoverable across the platform. |
| Auth flow | JWT on every request. ExtAuth at the gateway. MCP servers have zero auth logic — all enforcement is at the platform layer. |
| AgentGateway UI | Routes, backends, auth policy, rate limits, and traffic audit log — all in one place. |
| Gloo Mesh UI | Multi-cluster topology in one place. Federation state, ambient mesh health, east-west tunnel status. |
| Federation | Bidirectional. Symmetric. Add clusters without changing agent code. |

---

## Troubleshooting

**AgentRegistry UI shows no servers:**
```bash
KUBE_CONTEXT=cluster1 ./scripts/07-register-mcp-servers.sh
```

**AgentGateway Enterprise UI not loading on :4000:**
```bash
kubectl --context cluster1 -n agentgateway-system get pod -l app=solo-enterprise-ui
kubectl --context cluster1 -n agentgateway-system port-forward svc/solo-enterprise-ui 4000:80
```

**Gloo Mesh UI not loading on :8090:**
```bash
kubectl --context cluster1 -n gloo-mesh get pod -l app=gloo-mesh-ui
kubectl --context cluster1 -n gloo-mesh port-forward svc/gloo-mesh-ui 8090:8090
```

**send-traffic.sh fails at JWT step:**
```bash
kubectl --context cluster1 -n dex get pods
kubectl --context cluster1 -n dex get cm dex-config -o yaml | grep -A5 agw-client
```

**Cluster2 → Cluster1 reverse route not working:**
```bash
kubectl --context cluster2 -n agentgateway-system get httproute
kubectl --context cluster2 -n agentgateway-system get agentgatewaybackend mcp-backends-cluster1
```
