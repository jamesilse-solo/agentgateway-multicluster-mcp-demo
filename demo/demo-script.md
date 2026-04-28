# Singtel × Solo.io — 30-Minute Demo Script

**Audience:** Singtel enterprise architects  
**Presenter:** Singtel SE team  
**Duration:** 30 minutes  
**Core messages:** (1) Centralized MCP gateway + registry, (2) Cross-cluster federation

---

## Pre-Demo Checklist (T-15 min)

Run these before the call starts. Everything should be green before screen-share.

```bash
# 1. Start all port-forwards (leave this running in a dedicated terminal)
KUBE_CONTEXT=cluster1-singtel ./demo/portforward.sh

# 2. Verify AgentRegistry UI loads and shows 3 servers
open http://localhost:8080
# → Navigate to "Servers" tab; confirm 3 entries are present

# 3. Verify AgentGateway Enterprise UI loads
open http://localhost:9978
# → Should show routes/policies; if blank try :9093

# 4. Confirm AGW LB resolves
kubectl --context cluster1-singtel -n agentgateway-system get svc agentgateway-hub
# → Copy the EXTERNAL-IP / hostname for reference

# 5. Verify local MCP works
AGW_LB=<lb-hostname> ./demo/send-traffic.sh
# → Should complete with tool list and echo response

# 6. Verify cross-cluster MCP works
AGW_LB=<lb-hostname> ./demo/send-traffic.sh --remote
# → Same result, different cluster

# 7. Open demo-deck.html in browser, navigate to slide 1
open ./demo/demo-deck.html
```

Have two browser tabs open: AgentRegistry UI, AgentGateway Enterprise UI.  
Have two terminal tabs ready: portforward.sh (already running), demo traffic commands.

---

## Segment 0 — Architecture Context (4 min)

**Show:** `demo/demo-deck.html` — slides 1 and 2  
**Goal:** Frame the problem. Set up the two core concepts before any live demo.

**Slide 1 — Title**

> "What we've deployed here is a complete federated AI agent infrastructure on your two EKS clusters. The goal today is to show you two things: how you centralize and govern all MCP tool traffic through a single gateway and registry, and how that gateway transparently federates calls across clusters — so your agents never need to know which cluster a tool lives on."

**Slide 2 — Architecture**

> "On the left, cluster1 is the hub. It runs AgentGateway Enterprise — that's the single policy enforcement point for every MCP call. Everything flows through it: authentication, rate limiting, routing, observability."

> "In green, also on cluster1, is AgentRegistry. That's your MCP service catalog. Any agent that needs to call a tool starts there — it does a lookup by name, gets back a URL, and calls through the gateway."

> "On the right, cluster2 is a spoke. It runs its own MCP servers — tools and data services. The gateway on cluster1 federates calls to cluster2 over HBONE mutual TLS — that's the blue line at the bottom. The east-west gateways on both clusters handle the encrypted tunnel. Your agents make one call to the same gateway LB and the routing is completely transparent."

**Transition:**

> "Let's look at the registry first — this is where any new MCP server gets registered."

---

## Segment 1 — AgentRegistry (6 min)

**Show:** Browser tab with `http://localhost:8080`  
**Goal:** Show the catalog, walk through an entry, demonstrate live registration.

**Open the Servers tab**

> "This is the AgentRegistry UI. You can see three servers already registered — these are the ones we set up for this POC."

**Click on `com.amazonaws/mcp-everything-local`**

> "The naming convention is important. Reverse-domain notation — the namespace maps to the URL domain. `com.amazonaws` means this server lives on an amazonaws.com hostname — in this case, the AgentGateway's load balancer address. The registry validates that the URL you register matches the namespace. This prevents any team from squatting on another team's namespace."

> "The entry includes the URL — which is the AgentGateway endpoint at `/mcp` — a schema reference, a version, and a title. An agent that wants to call this server just does a GET on `/v0/servers?search=com.amazonaws` and gets back everything it needs to initialize an MCP session."

**Register a new server live**

> "Let me show you how a new server gets registered. This is what a platform team would do when they onboard a new tool."

Using the UI's create form or via curl in a terminal:

```bash
# Live registration — run in terminal visible to audience
curl -s -X POST http://localhost:8080/v0/servers \
  -H "Content-Type: application/json" \
  -d '{
    "$schema": "https://static.modelcontextprotocol.io/schemas/2025-10-17/server.schema.json",
    "name": "com.amazonaws/mcp-demo-live",
    "title": "Live Demo Server",
    "description": "Registered live during the Singtel demo",
    "version": "1.0.0",
    "remotes": [{"type": "streamable-http", "url": "http://'"${AGW_LB:-agw-lb}"'/mcp"}]
  }' | python3 -m json.tool
```

> "And that's it. One API call. The entry appears in the catalog immediately and propagates to the gateway via gRPC — no restart, no config change. In production you'd wrap this in your CI/CD pipeline or a self-service portal."

> "This is your organization's MCP service catalog. Any agent that needs a tool starts here — not with a hardcoded URL in the agent code."

---

## Segment 2 — Agent Traffic (5 min)

**Show:** Terminal running `send-traffic.sh`  
**Goal:** Show the full agent → gateway → tool flow. Demonstrate auth is enforced.

Run the script with the audience watching the terminal:

```bash
KUBE_CONTEXT=cluster1-singtel ./demo/send-traffic.sh
```

**Narrate each step as it runs:**

**Step 1 — JWT from Dex:**  
> "The agent first gets a JWT from Dex, the OIDC identity provider. In this demo it's a password grant for `demo@example.com` — in production this would be a service account credential or an OAuth client credentials flow. The gateway only accepts requests with a valid JWT."

**Step 2 — MCP session initialize:**  
> "Now the agent initializes an MCP session. It sends an HTTP POST to the AgentGateway's `/mcp` endpoint with the Bearer token and a standard JSON-RPC `initialize` request. AgentGateway's ExtAuth validates the token against Dex — if it's invalid, the request is rejected with a 401 before it ever reaches the tool server. Here we get back an Mcp-Session-Id — the session is established."

**Step 3 — List tools:**  
> "With the session open, the agent lists available tools. These are the tools exposed by the MCP server on cluster1. The agent didn't need to know the server's address — it could have looked it up from the registry. The request went through the gateway, was authenticated, and reached the backend."

**Step 4 — Call a tool:**  
> "Finally, the agent calls the `echo` tool. We get the response back through the same authenticated, governed path. Every one of these calls is logged and traceable in the gateway — which we'll look at next."

---

## Segment 3 — AgentGateway Enterprise UI — Governance (8 min)

**Show:** Browser tab with `http://localhost:9978`  
**Goal:** Show the control plane — routes, auth policy, rate limits, request logs.

**Routes view**

> "This is the AgentGateway Enterprise UI — the single pane of glass for every MCP call on the platform. Let's look at routes first."

Navigate to routes/backends:

> "You can see the three routes we configured: `/mcp` routing to the local MCP server on cluster1, `/mcp/remote` routing to cluster2, and `/mcp/registry` routing to AgentRegistry. These are standard HTTPRoutes — declarative, GitOps-compatible, no manual config."

**Authentication policy**

Navigate to auth/policies:

> "The authentication policy is using ExtAuth with Dex as the JWT validator. Any request to `/mcp` or any sub-path must present a valid JWT. The policy is enforced at the gateway — the MCP servers themselves have no auth logic. This is the clean separation: the gateway owns security, the servers own functionality."

**Rate limiting**

> "Rate limiting is also configured here. You can set per-identity limits — so if a specific agent or BU's service account starts flooding the gateway, it gets throttled without affecting other callers. The MCP servers never see the excess traffic."

**Request logs / traffic**

Navigate to request logs or traces:

> "And here's the traffic we just sent — you can see the session initializations, the tools/list call, and the tools/call. Each entry shows the path, the response code, the latency, and — if you drill in — the JWT identity that made the call. This is your audit trail."

> "This is the single pane of glass for every MCP call in your platform. Every tool call by every agent is visible here, governed here, and auditable here."

---

## Segment 4 — Cross-Cluster Federation (5 min)

**Show:** Terminal running `send-traffic.sh --remote`, then AGW UI  
**Goal:** Show the exact same agent flow succeeding against cluster2.

```bash
KUBE_CONTEXT=cluster1-singtel ./demo/send-traffic.sh --remote
```

**Narrate as it runs:**

> "Now we're sending the same MCP call but to `/mcp/remote`. Watch — the agent code is identical. Same JWT, same session initialization, same tools/list. The only difference is the path."

After tools/list succeeds:

> "Same tools, same response — but this call went to cluster2. Let me show you what happened under the covers."

Back in the AgentGateway Enterprise UI, show the `/mcp/remote` route:

> "The HTTPRoute for `/mcp/remote` points to an AgentgatewayBackend that resolves to the east-west gateway on cluster2. The hub gateway forwarded the request over HBONE — that's an HTTP/2 CONNECT tunnel with mutual TLS — to the spoke proxy on cluster2, which then delivered it to the local MCP server there."

> "The key point: the agent made one call to the same AgentGateway load balancer it always uses. It had no idea the tool was on a different cluster. The gateway handled all the routing, all the encryption, all the identity verification. The agent is completely location-unaware."

> "When you add a third cluster — whether it's another EKS region or an on-premises OpenShift cluster — you register it as a spoke, add an HTTPRoute, and existing agents start using it immediately. No agent code changes."

---

## Segment 5 — Q&A (2 min)

**Show:** Slide 5 (Federation) as backdrop  
**Goal:** Invite questions. Have these prompts ready if the room is silent.

**Suggested prompts if silence:**

- "What's your current approach for controlling which agents can call which tools? Is that enforced at the platform layer or inside each tool server?"

- "Does this federation model match how your BU separation works — where different business units own different clusters or namespaces?"

- "You mentioned AI agents running in multiple environments. How are those agents currently provisioned with credentials to call external services?"

- "How important is the audit trail for you — being able to say 'agent X called tool Y at time Z with this identity'?"

---

## Key Messages Reference

| Segment | Core message |
|---------|-------------|
| Architecture | Solo adds a thin, centrally-managed layer. Every AI agent finds its tools through the registry and calls them through the gateway. Traffic never bypasses policy. |
| Registry | This is your organization's MCP service catalog. Agents don't need hardcoded URLs. New tools get registered once and are immediately discoverable. |
| Agent traffic | The agent presents a JWT. The gateway validates it. No valid token, no tools. Every call is authenticated, governed, and logged. |
| Gateway UI | One control plane for every MCP call. Auth, routing, rate limits, and observability — all in one place. |
| Federation | Agents are location-unaware. The gateway handles all cross-cluster routing. Add new clusters as spokes without changing any agent code. |

---

## Troubleshooting

**AgentRegistry UI shows no servers:**
```bash
KUBE_CONTEXT=cluster1-singtel ./scripts/07-register-mcp-servers.sh
```

**Port-forward for AgentGateway UI not working:**
```bash
kubectl --context cluster1-singtel -n agentgateway-system get svc enterprise-agentgateway
# check port names and available ports
```

**send-traffic.sh fails at JWT step:**
```bash
# Verify Dex pod is running
kubectl --context cluster1-singtel -n dex get pods
# Verify agw-client is configured in Dex
kubectl --context cluster1-singtel -n dex get cm dex-config -o yaml | grep -A5 agw-client
```

**send-traffic.sh --remote fails:**
```bash
# Verify cross-cluster route exists
kubectl --context cluster1-singtel -n agentgateway-system get httproute
# Verify spoke backend
kubectl --context cluster1-singtel -n agentgateway-system get agentgatewaybackend
```
