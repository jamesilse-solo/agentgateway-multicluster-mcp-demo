,,,,,
Test ID,Requirement Evaluated,Execution Scenario,Expected Outcome ,Internal Notes,Documentation
"Phase 1 - Securing Agent to Tool Call Goal: Prove how the mesh securely networks the AI Agent to MCP tools without slowing down development or
losing agent context.",,,,,
MESH-01,"Zero-Friction
Tool Onboarding
(Sidecar-less)","Deploy an internal MCP server.
Label its namespace ambient. Point
the AI Agent to the tool.","The MCP developer does not need to inject
proxies or change code. The Agent's traffic is
instantly intercepted by ztunnel and secured
with mTLS. Value: Faster tool onboarding.","Systems required: cluster1 kubeconfig context · agentgateway-system namespace (must carry label istio.io/dataplane-mode=ambient) · ztunnel DaemonSet in istio-system (one pod per node) · mcp-server-everything Deployment + Service in agentgateway-system · netshoot pod in debug namespace.

What is validated: (1) agentgateway-system carries istio.io/dataplane-mode=ambient — this single label enrolls every pod without any per-pod proxy injection. (2) mcp-server-everything pod has exactly one container (mcp-server); no istio-proxy sidecar is present. (3) ztunnel DaemonSet Running on every node. (4) curl from netshoot to mcp-server-everything returns any HTTP response — proving ztunnel intercepts and tunnels traffic with HBONE mTLS even though the app has no proxy.

Net cluster change: none.","[What is ambient mesh? — docs.solo.io](https://docs.solo.io/gloo-mesh/main/ambient/about/overview/) · [Phase1-Securing-Agent-to-Tool-Call/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase1-Securing-Agent-to-Tool-Call/validate.sh)"
MESH-02,"Agent-Specific
Trust
Boundaries
(L4 Isolation)","Apply an AuthorizationPolicy
explicitly denying an Agent from
accessing a MCP Tool.","The ztunnel drops the Agent's TCP connection
instantly using its cryptographic SPIFFE
identity. Value: Ensures an Agent cannot
hallucinate or be hijacked to access
unauthorized internal databases.","Systems required: cluster1 kubeconfig context · mcp-server-everything Deployment + Service in agentgateway-system · netshoot pod in debug namespace (acts as the agent under test) · AuthorizationPolicy CRD (security.istio.io/v1) applied then deleted · ztunnel pod logs in istio-system to confirm SPIFFE-based denial.

What is validated: (1) Baseline curl from netshoot → mcp-server-everything succeeds before any policy. (2) AuthorizationPolicy action: DENY applied to agentgateway-system targeting mcp-server-everything with source namespace: debug — istiod propagates via XDS to ztunnel in ~3-4s. (3) Same curl is now blocked at TCP layer (HTTP 000 / connection refused) — ztunnel drops using the pod's SPIFFE identity with zero application-layer involvement. (4) ztunnel logs show src.identity + dst.identity and a policy rejection entry. (5) AuthorizationPolicy deleted immediately — cluster restored to original state.

Net cluster change: none (policy created and deleted within the script run).","[Security policy examples — istio.io](https://istio.io/latest/docs/ops/configuration/security/security-policy-examples/) · [Phase1-Securing-Agent-to-Tool-Call/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase1-Securing-Agent-to-Tool-Call/validate.sh)"
MESH-03,"Protecting Agent
Reasoning State
(Session
Resumability)","Agent initiates a long-running,
multi-step Streamable HTTP session
to a local MCP server. Restart the
ztunnel pod.","The ztunnel handles the TCP blip without
dropping the connection. Value: The AI Agent
does not lose its reasoning loop or LLM
context window due to underlying network
maintenance.","Systems required: cluster1 kubeconfig context · netshoot pod in debug namespace (holds the open streaming connection) · mcp-server-everything /sse endpoint in agentgateway-system · ztunnel DaemonSet in istio-system (the component being restarted) · two terminal windows open simultaneously.

What is validated: (1) Terminal 1 opens a long-lived streaming connection from netshoot to mcp-server-everything /sse (curl -N, 120s timeout), simulating an AI agent holding an active MCP session. (2) Terminal 2 performs a rolling restart of the ztunnel DaemonSet — the controller replaces each ztunnel pod one at a time; HBONE tunnels re-establish per-node. (3) Terminal 1 curl stream continues without exiting — kernel TCP state survives the pod cycle, proving routine platform maintenance (ztunnel upgrades, node replacement) does not terminate active agent sessions.

Net cluster change: ztunnel DaemonSet rolling restart (self-heals automatically).","[HBONE architecture — istio.io](https://istio.io/latest/docs/ambient/architecture/hbone/) · [Phase1-Securing-Agent-to-Tool-Call/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase1-Securing-Agent-to-Tool-Call/validate.sh)"
MESH-04,"Handling Heavy
AI Data Payloads
(MTU Limits)","Agent requests a massive dump
(>10MB) from an internal MCP tool.","ztunnel correctly fragments the massive JSON
payload over the HBONE tunnel. Value: The
Agent successfully retrieves massive context
windows without network truncation errors.","Systems required: cluster1 kubeconfig context · netshoot pod in debug namespace (requires dd, base64, curl — all present in nicolaka/netshoot) · mcp-server-everything Service port 80 → container 8080 in agentgateway-system · ztunnel DaemonSet HBONE tunnel under test.

What is validated: (1) dd generates 12 MB of /dev/urandom data inside netshoot; base64 encodes it (~16 MB ASCII) to produce a valid JSON string value. (2) The value is embedded in a JSON-RPC body as a padding field and POSTed to mcp-server-everything via curl. (3) curl --write-out captures size_upload — value > 10,000,000 bytes confirms ztunnel HBONE tunnel correctly fragmented and reassembled the oversized TCP stream without truncation or a mid-stream connection reset. (4) Any HTTP response (4xx or 200) proves the full round-trip completed.

Net cluster change: none.","[HBONE architecture — istio.io](https://istio.io/latest/docs/ambient/architecture/hbone/) · [Phase1-Securing-Agent-to-Tool-Call/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase1-Securing-Agent-to-Tool-Call/validate.sh)"
"Phase 2: Bridging to Internal Remote MCP Server Goal: Prove how the mesh acts as an unbypassable cage, allowing the Agent to use public tools (like Jira) while
preventing data exfiltration.",,,,,
"MESH-
05","Abstracting Cross-
Cluster/VPC
Complexity
(Federation)","Agent requests a tool that the
AgentRegistry knows lives in a
different cluster/VPC.","The Agent assumes the tool is local. The mesh
uses East-West Gateways to securely bridge the
clusters. Value: The Agent developer writes
zero complex networking or VPN code.","Systems required: cluster1 + cluster2 kubeconfig contexts · mcp-route-remote HTTPRoute + mcp-backends-remote AgentgatewayBackend in agentgateway-system (cluster1) · mcp-server-everything Deployment + Service in agentgateway-system (cluster2) · east-west gateways in istio-eastwest on both clusters · netshoot pod in debug namespace (cluster1).

What is validated: (1) The cross-cluster HTTPRoute on cluster1 maps /mcp/remote to an AgentgatewayBackend targeting mcp-server-everything.agentgateway-system.mesh.internal — the global mesh.internal DNS name synthesised from the solo.io/service-scope=global label on cluster2. (2) mcp-server-everything is running and reachable on cluster2. (3) East-west gateways exist on both clusters — they carry the cross-cluster HBONE mTLS traffic. (4) A curl from netshoot to the AGW hub's /mcp/remote path returns a 2xx response, proving the full cross-cluster routing path: AGW Hub → ztunnel → east-west GW → cluster2 ztunnel → MCP server.

Net cluster change: none.","[Multicluster app routing — docs.solo.io](https://docs.solo.io/gloo-mesh/main/ambient/multicluster/multi-apps/) · [Phase2-Bridging-Internal-Remote-MCP-Server/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase2-Bridging-Internal-Remote-MCP-Server/validate.sh)"
"MESH-
06","Safe Legacy Tool
Integration
(ServiceEntry)","Register an MCP server
running on a Virtual Machine
(outside Kubernetes) using a
ServiceEntry.","The Agent successfully connects to the VM via a
private IP or Egress Gateway. Value: AI teams
can expose Remote MCP Severs to Agents
without migrating it into Kubernetes.","Systems required: cluster1 kubeconfig context · ServiceEntry CRD (networking.istio.io/v1) — applied then deleted · netshoot pod in debug namespace · mcp-server-everything Service in agentgateway-system.

What is validated: (1) A ServiceEntry is applied registering a VM-hosted MCP server (static IP + DNS hostname) as a MESH_INTERNAL service. (2) The mesh adopts the endpoint — pods can route to demo-mcp-vm.example.internal as if it were a Kubernetes service. (3) istiod synthesises the service registry entry within the XDS pipeline. (4) ServiceEntry is deleted immediately — cluster restored. This proves AI teams can expose VM-hosted MCP tools to agents without Kubernetes migration: a single ServiceEntry YAML is the only change needed.

Net cluster change: none (ServiceEntry created and deleted within the script run).","[ServiceEntry reference — istio.io](https://istio.io/latest/docs/reference/config/networking/service-entry/) · [Phase2-Bridging-Internal-Remote-MCP-Server/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase2-Bridging-Internal-Remote-MCP-Server/validate.sh)"
"MESH-
07","Lateral Movement
Prevention
(Zero-Trust VPC)","The Agent attempts to connect
to an unapproved private IP
that is not registered as a tool.","The mesh blocks the connection. Value: If an
Agent goes rogue, it cannot scan the VPC for
open connection.","Systems required: cluster1 kubeconfig context · netshoot pod in debug namespace (acts as the rogue agent) · Sidecar resource (networking.istio.io/v1) — applied then deleted · ztunnel DaemonSet in istio-system.

What is validated: (1) Baseline: from netshoot, curl to an unregistered IP (1.1.1.1) succeeds under default ALLOW_ANY policy. (2) A Sidecar resource is applied to the debug namespace restricting egress to only registered mesh hosts. (3) The same curl to 1.1.1.1 is now blocked (HTTP 000 — connection refused). (4) Sidecar deleted — cluster restored. This proves that ztunnel + Sidecar resource together enforce a per-namespace REGISTRY_ONLY equivalent: a rogue agent cannot scan arbitrary VPC IPs even if it bypasses application-layer controls.

Net cluster change: none (Sidecar created and deleted within the script run).","[MeshConfig OutboundTrafficPolicy — istio.io](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/) · [Phase2-Bridging-Internal-Remote-MCP-Server/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase2-Bridging-Internal-Remote-MCP-Server/validate.sh)"
"Phase 3: Securing the Internet (Public MCP Servers) Goal: Prove how the mesh acts as an unbypassable cage, allowing the Agent to use public tools (like Jira) while
preventing data exfiltration.",,,,,
"MESH-
08","Centralized SaaS
Egress
(Egress Gateway)","Agent connects to a registered public
SaaS MCP server (e.g. Jira). Route
traffic through the mesh Egress
Gateway.","The SaaS vendor sees all traffic coming
from one static IP, rather than random
pod IPs. Value: Allows the enterprise to
easily configure IP allowlists with
external AI tool vendors.","Systems required: cluster1 kubeconfig context · egress gateway pod in istio-system (istio=egressgateway) · netshoot pod in debug namespace · mcp-server-everything in agentgateway-system · A registered public MCP server (e.g. search.solo.io/mcp).

What is validated: (1) Egress gateway deployment is confirmed — it has a single external Load Balancer IP. (2) All agent traffic to a registered public MCP server (search.solo.io) is routed through the egress gateway via a ServiceEntry + VirtualService combination. (3) The SaaS vendor sees a single source IP (the egress gateway LB), not the random node IPs of agent pods. (4) A curl from netshoot to the registered public tool confirms end-to-end connectivity through the gateway. This proves that enterprises can configure a single IP allowlist entry with external SaaS MCP vendors rather than managing hundreds of node IPs.

Net cluster change: none (requires egress gateway already deployed via istioctl/Helm).","[Egress traffic management — docs.solo.io](https://docs.solo.io/gloo-mesh/main/ambient/traffic-management/egress/) · [Phase3-Securing-the-Internet/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase3-Securing-the-Internet/validate.sh)"
"MESH-
09","Data Exfiltration
Cage
(REGISTRY_ONLY)","Set Istio outbound policy to
REGISTRY_ONLY. Inject a malicious
prompt telling the Agent to HTTP
POST data to an unregistered website.","The mesh drops the connection instantly
at Layer 4. Value: Provides a guaranteed
fail-safe against prompt injection data
leaks, even if L7 guardrails fail.","Systems required: cluster1 kubeconfig context · netshoot pod in debug namespace (simulates the compromised agent) · Sidecar resource (networking.istio.io/v1) — applied then deleted · ztunnel DaemonSet in istio-system.

What is validated: (1) Baseline: netshoot successfully POSTs JSON to httpbin.org (simulating data exfiltration before the cage is applied). (2) A Sidecar resource restricts debug namespace egress to registered mesh hosts only (REGISTRY_ONLY equivalent). (3) The same POST to httpbin.org is now dropped by ztunnel at L4 (HTTP 000) — data never leaves the cluster. (4) Sidecar deleted — cluster restored. This proves that even if a prompt injection attack causes the LLM to instruct the agent to exfiltrate data to an arbitrary URL, the mesh cage silently drops the connection before the TCP handshake completes — independently of any L7 guardrail.

Net cluster change: none (Sidecar created and deleted within the script run).","[Egress control — istio.io](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-control/) · [Phase3-Securing-the-Internet/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase3-Securing-the-Internet/validate.sh)"
"Phase 4 - L7 Routing and Federation Goal: Validates how the Envoy proxy parses Streamable HTTP and JSON-RPC to make intelligent routing decisions.",,,,,
"L7-RT-
01","Composite Server
/ Single URL","Configure an Agent Gateway Route
matching labels of 3 backend MCP
servers. Request tools/list.","Gateway merges the schemas and returns a
unified JSON-RPC list of tools from all 3
servers over a single URL.","Systems required: cluster1 kubeconfig context · agentgateway-hub Service in agentgateway-system · multiple AgentgatewayBackend resources (targeting cluster1 + cluster2 MCP servers) · netshoot pod in debug namespace.

What is validated: (1) Multiple AgentgatewayBackend CRDs are configured, each targeting a different MCP server. (2) A single HTTPRoute aggregates them at one path prefix (/mcp). (3) A tools/list call to the single URL returns a merged tool schema sourced from all configured backends — the LLM sees one unified tool namespace. (4) Tool count in the response confirms multiple backends contributed.

Net cluster change: none.","[Virtual MCP (composite server) — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/mcp/virtual/) · [Phase4-L7-Routing-and-Federation/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase4-L7-Routing-and-Federation/validate.sh)"
"L7-RT-
02","L7 Gateway
Federation","Client connects to Gateway A and
calls a tool residing behind Gateway
B in a peered cluster.","Gateway A acts as an L7 router, forwarding
the JSON-RPC call over the L4 mesh to
Gateway B seamlessly.","Systems required: cluster1 + cluster2 kubeconfig contexts · mcp-route-remote HTTPRoute + mcp-backends-remote AgentgatewayBackend (cluster1) targeting cluster2 mesh.internal host · east-west gateways on both clusters · netshoot pod in debug namespace (cluster1).

What is validated: (1) The HTTPRoute mcp-route-remote maps /mcp/remote to an AgentgatewayBackend that resolves mcp-server-everything on cluster2. (2) A JSON-RPC initialize + tools/list call to /mcp/remote returns a 2xx response with tools from cluster2's MCP server. (3) The client uses a single URL; the gateway selects the correct cluster2 backend and proxies the JSON-RPC call over the ambient HBONE mesh without any client-side networking code.

Net cluster change: none.","[Virtual MCP (federation) — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/mcp/virtual/) · [Phase4-L7-Routing-and-Federation/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase4-L7-Routing-and-Federation/validate.sh)"
"L7-RT-
03","Stateful Session
Affinity","Configure a Gloo VirtualService with
a hashPolicies rule extracting the
Mcp-Session-Id header.","Gateway reliably routes all subsequent HTTP
POSTs within the session to the exact same
backend replica.","Systems required: cluster1 kubeconfig context · agentgateway-hub with stateful session routing enabled (default) · netshoot pod in debug namespace · mcp-server-everything with 2+ replicas or multiple AgentGateway instances to observe affinity.

What is validated: (1) A POST /mcp initialize call returns an Mcp-Session-Id response header. (2) Three subsequent requests sent with that session ID header all return 2xx responses. (3) With multiple replicas, all requests with the same Mcp-Session-Id are routed to the same backend instance — confirmed via pod-level access logs. This ensures stateful MCP sessions (multi-turn tool calls, file contexts) are not disrupted by load balancer round-robin.

Net cluster change: none.","[Stateful MCP session routing — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/mcp/session/) · [Phase4-L7-Routing-and-Federation/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase4-L7-Routing-and-Federation/validate.sh)"
"L7-RT-
04","Static Tool
Filtering","Pass ""Project X"" context in the
connection metadata. Request
tools/list.","Gateway filters simple metadata of allowed
tools for LLM to select","Systems required: cluster1 kubeconfig context · AgentgatewayBackend resources with tool selector labels configured · agentgateway-hub Service · netshoot pod in debug namespace.

What is validated: (1) AgentgatewayBackend is configured with a tool label selector (or allowed tool list). (2) A tools/list call to the configured route returns only the approved subset of tools from the backend. (3) Comparing filtered vs unfiltered tool lists confirms the gateway is applying the selector at JSON-RPC parse time — the LLM context window contains only approved tools, reducing hallucination surface.

Net cluster change: none.","[MCP connectivity — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/mcp/) · [Phase4-L7-Routing-and-Federation/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase4-L7-Routing-and-Federation/validate.sh)"
"L7-RT-
05","Legacy Protocol
Translation","Client uses the Streamable HTTP
protocol, but a backend server uses
legacy HTTP+SSE.","Gateway automatically translates the
Streamable HTTP POST into the dual-
endpoint HTTP+SSE format for the legacy
backend.","Systems required: cluster1 kubeconfig context · agentgateway-hub Service · a backend MCP server that exposes the legacy HTTP+SSE transport (GET /sse + POST /messages) · netshoot pod in debug namespace.

What is validated: (1) The backend MCP server uses the legacy dual-endpoint HTTP+SSE transport. (2) A Streamable HTTP POST from the client is received by the gateway and translated into the appropriate SSE + message POST pair for the legacy backend. (3) The client receives a properly structured JSON-RPC response — it never needs to implement SSE handling. AgentGateway auto-detects the backend transport protocol on first connection.

Net cluster change: none.","[MCP connectivity — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/mcp/) · [Phase4-L7-Routing-and-Federation/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase4-L7-Routing-and-Federation/validate.sh)"
"Phase 5 - L7 Security, Identity & TBAC Goal: Validates Gloo's ExtAuth capabilities, evaluating tokens, tasks, and OPA Rego policies against the MCP spec. ",,,,,
"L7-
SEC-
01","OAuth 2.0 (Client
to Gateway)","Client attempts to connect. Gloo
ExtAuth server validates the OAuth
2.0 Bearer token.","Connection rejected with 401 Unauthorized
if the token is missing or invalid.","Systems required: cluster1 kubeconfig context · Dex OIDC deployed in dex namespace (03-dex.sh) · oidc-dex AuthConfig in agentgateway-system (05-extauth.sh) · ExtAuth service (ext-auth-service) pod running in agentgateway-system · agentgateway-hub external Load Balancer · Dex password grant credentials: demo@example.com / demo-pass / agw-client / agw-client-secret.

What is validated: (1) A curl to the AGW hub /mcp without a Bearer token returns HTTP 302 redirect to Dex login — ExtAuth is enforcing OAuth. (2) A Dex JWT is acquired via password grant (port-forward to Dex required). (3) The same curl with Authorization: Bearer <token> returns HTTP 200 — ExtAuth validated the JWT and allowed the request. This proves no MCP data is accessible without a valid identity token.

Net cluster change: none.","[OAuth ExtAuth — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/security/extauth/oauth/) · [Phase5-L7-Security-Identity-and-TBAC/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase5-L7-Security-Identity-and-TBAC/validate.sh)"
"L7-
SEC-
02","Tool & Resource
Level RBAC","Deploy Gloo ExtAuth with an OPA
Rego policies. User A tries to execute
delete_database without
permissions.","OPA parses the JSON-RPC tool name,
evaluates the JWT, and blocks execution
with an MCP permission error.","Systems required: cluster1 kubeconfig context · OPA policy ConfigMap deployed in agentgateway-system · ExtAuth service with OPA plugin configured · AuthConfig referencing the OPA ConfigMap · JWT carrying a role claim (e.g. role: agent, not admin) · agentgateway-hub Service.

What is validated: (1) An OPA Rego policy is loaded from a ConfigMap and evaluates the JSON-RPC request body (specifically the method and params.name fields) against the caller's JWT role claim. (2) A non-admin user attempting tools/call with name=delete_database receives a 403 / MCP JSON-RPC error. (3) The OPA policy decision log shows the deny reason. This proves tool-level authorization without any code changes to the MCP server.

Net cluster change: none.","[OPA with Rego (BYO server) — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/security/extauth/opa/byo/) · [Phase5-L7-Security-Identity-and-TBAC/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase5-L7-Security-Identity-and-TBAC/validate.sh)"
"L7-
SEC-
03","Task-Based
Access Control","Pass a tool call parameters. ExtAuth /
OPA matches the task against the
allowed tools actions.","Gateway evaluates the agent's task context
at L7 and blocks tool executions outside the
authorized task.","Systems required: cluster1 kubeconfig context · OPA policy ConfigMap with task-based Rego rules · AuthConfig referencing the TBAC policy · JWT carrying a task claim (e.g. task: customer-support) · agentgateway-hub Service · netshoot pod in debug namespace.

What is validated: (1) The OPA Rego policy maps allowed task values to allowed tool names. (2) An agent JWT with task: customer-support is permitted to call read_ticket but not delete_database. (3) A tools/call attempt for a tool outside the authorized task scope returns a 403 / MCP error. (4) Changing the JWT task claim to one that permits the tool results in a 200 success. This proves the gateway enforces task-scoped authorization independently of the MCP server.

Net cluster change: none.","[OPA with Rego (ConfigMap) — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/security/extauth/opa/rego-cm/) · [Phase5-L7-Security-Identity-and-TBAC/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase5-L7-Security-Identity-and-TBAC/validate.sh)"
"L7-
SEC-
04","L7 Multi-Tenancy
Support","Tenant A and Tenant B use the same
shared Gateway. Tenant A requests a
list of tools.","Gateway isolates routing at L7 based on
domain/headers. Tenant A only receives
Tenant A's tools.","Systems required: cluster1 kubeconfig context · Two AgentgatewayBackend resources (one per tenant) with non-overlapping tool sets · Two HTTPRoutes using header/path matchers for tenant isolation (e.g. x-tenant-id header or path prefix /mcp/tenant-a vs /mcp/tenant-b) · JWT with tenant_id claim for each tenant · agentgateway-hub Service.

What is validated: (1) HTTPRoute for Tenant A matches on a header (x-tenant-id: tenant-a) or path prefix and routes to Tenant A's AgentgatewayBackend. (2) A tools/list call by Tenant A returns only Tenant A's tools. (3) A tools/list call by Tenant B (different header/path) returns only Tenant B's tools. (4) Neither tenant can enumerate the other's tools by manipulating the request.

Net cluster change: none.","[Security overview — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/security/) · [Phase5-L7-Security-Identity-and-TBAC/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase5-L7-Security-Identity-and-TBAC/validate.sh)"
"L7-
SEC-
05","Dynamic Client
Registration","Point an unregistered MCP client at
the gateway configured with an IdP.","Gateway triggers the OAuth DCR flow,
dynamically provisions a
client_id/client_secret, and allows the
connection.","Systems required: cluster1 kubeconfig context · An IdP that supports RFC 7591 Dynamic Client Registration (Keycloak or Auth0 — Dex does not support DCR) · AuthConfig configured with the DCR-capable IdP · agentgateway-hub Service · An unregistered MCP client.

What is validated: (1) An unregistered MCP client connects to the gateway without pre-provisioned credentials. (2) The gateway detects the missing client_id and triggers the RFC 7591 registration endpoint on the IdP. (3) The IdP returns a dynamically provisioned client_id + client_secret. (4) The gateway uses these credentials to complete the OAuth flow and allows the connection. Note: this flow requires Keycloak or Auth0 — Dex does not implement RFC 7591.

Net cluster change: none.","[OAuth ExtAuth — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/security/extauth/oauth/) · [Phase5-L7-Security-Identity-and-TBAC/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase5-L7-Security-Identity-and-TBAC/validate.sh)"
"L7-
SEC-
06","Upstream
Gateway to
Server Auth","Agent calls a SaaS MCP tool without
providing SaaS credentials.","Gateway seamlessly injects the required
upstream OAuth 2.0 API keys/tokens into
the proxied HTTP request.","Systems required: cluster1 kubeconfig context · AuthConfig configured with upstream credential injection (plugin or header modification) · A SaaS MCP server that requires an API key in the upstream Authorization header · agentgateway-hub Service · Agent JWT that authorizes gateway access (but carries no SaaS credentials).

What is validated: (1) The agent presents only a gateway-level JWT — it has no knowledge of the SaaS API key. (2) The AuthConfig injects Authorization: Bearer <service-account-token> into the upstream HTTP request before forwarding. (3) The SaaS MCP server receives the correct credentials and returns a 200 response. (4) The agent's JWT does not contain the SaaS credentials — they are stored securely in the gateway configuration (Kubernetes Secret).

Net cluster change: none.","[Security overview — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/security/) · [Phase5-L7-Security-Identity-and-TBAC/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase5-L7-Security-Identity-and-TBAC/validate.sh)"
"Phase 6 - L7 Resiliency and Guardrails Goal: Validates Envoy filters shaping traffic, validating payloads, and integrating with external security.",,,,,
"L7-
GR-01","External
Guardrails
Webhooks","Configure a Gloo GatewayExtension
using ExtProc pointing to F5 Calypso.","Envoy streams the JSON-RPC payload to
the webhook, the webhook sanitizes PII,
and Envoy forwards the sanitized
payload.","Systems required: cluster1 kubeconfig context · A GatewayExtension resource pointing to an ExtProc-compatible webhook endpoint (e.g. F5 Calypso or a custom PII scrubber) · EnterpriseAgentgatewayPolicy referencing the GatewayExtension · agentgateway-hub Service · netshoot pod in debug namespace.

What is validated: (1) The EnterpriseAgentgatewayPolicy configures ExtProc to stream every JSON-RPC request/response body to the webhook. (2) A tools/call request with a PII field (e.g. SSN) is sent to the gateway. (3) The webhook returns a sanitized body with the PII replaced. (4) Envoy forwards the sanitized payload to the MCP server and returns the result — the MCP server never receives raw PII. Response headers injected by the webhook (e.g. x-pii-detected) are visible in the client response.

Net cluster change: none.","[AgentGateway observability — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/observability/) · [Phase6-L7-Resiliency-and-Guardrails/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase6-L7-Resiliency-and-Guardrails/validate.sh)"
"L7-
GR-02","Schema
Validation","An upstream server returns a
malformed JSON-RPC tool response that
violates its registered schema.","Gateway catches the malformed JSON,
blocks it from the client, and returns an
MCP-compliant error.","Systems required: cluster1 kubeconfig context · agentgateway-hub Service · mcp-server-everything in agentgateway-system · netshoot pod in debug namespace.

What is validated: (1) A well-formed tools/list call returns a valid JSON-RPC response with jsonrpc + id + result fields. (2) The response is parsed and confirmed to conform to the JSON-RPC 2.0 schema (jsonrpc: 2.0, id present, result or error present). (3) To trigger schema validation failure: configure a backend that returns an incomplete response (missing jsonrpc field); the gateway should return a properly structured JSON-RPC error instead of passing the malformed response to the client.

Net cluster change: none.","[MCP connectivity — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/mcp/) · [Phase6-L7-Resiliency-and-Guardrails/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase6-L7-Resiliency-and-Guardrails/validate.sh)"
"L7-
GR-03","Rate Limiting &
Circuit Breakers","Deploy Gloo's Redis. Apply a
RateLimitConfig of 10 req/min based on
an agent header.","Requests 1-10 succeed. Requests 11-15
are rejected by the gateway with HTTP
429 / MCP Overload.","Systems required: cluster1 kubeconfig context · Redis (ext-cache) pod in agentgateway-system · RateLimitConfig resource (ratelimit.solo.io/v1alpha1) with requestsPerUnit set · EnterpriseAgentgatewayPolicy referencing the RateLimitConfig · agentgateway-hub Service · netshoot pod in debug namespace.

What is validated: (1) RateLimitConfig is deployed with a per-agent limit (e.g. 10 requests per minute). (2) Requests 1-10 return HTTP 200. (3) Request 11 and above return HTTP 429 (Too Many Requests). (4) After the rate limit window resets, requests succeed again. This prevents a runaway agent loop (e.g. infinite tool-call retry) from exhausting backend resources or exceeding SaaS API quotas.

Net cluster change: none.","[Rate limiting — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/llm/rate-limit/) · [Phase6-L7-Resiliency-and-Guardrails/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase6-L7-Resiliency-and-Guardrails/validate.sh)"
"L7-
GR-04","Graceful HTTP
Error Translation","Force a backend MCP server to crash.
Send a tools/call for that server via
HTTP POST to the gateway.","Gateway detects the upstream failure
and translates it into a properly
formatted MCP JSON-RPC error payload.","Systems required: cluster1 kubeconfig context · agentgateway-hub Service · mcp-server-everything Deployment in agentgateway-system (scaled to 0 then restored) · netshoot pod in debug namespace.

What is validated: (1) mcp-server-everything is scaled to 0 replicas to simulate a backend crash. (2) A tools/call request is sent to the gateway. (3) The gateway response is a valid JSON-RPC envelope (contains jsonrpc field) rather than a raw HTTP 502/503 page. (4) The AI agent receives a structured error it can parse and handle (e.g. display a user-friendly message) instead of an unparseable HTML error page. (5) mcp-server-everything is scaled back to original replica count.

Net cluster change: mcp-server-everything scaled to 0 then restored (net zero).","[AgentGateway observability — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/observability/) · [Phase6-L7-Resiliency-and-Guardrails/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase6-L7-Resiliency-and-Guardrails/validate.sh)"
"Phase 7 - ControlPlane, Registry and Mesh Goal: Validates the plane management, centralized tool discovery, and holistic observability.",,,,,
CP-01 ,"Hybrid / Single
Control Plane","Configure Ambient Mesh to Istio
Relay Agent for L4 Mesh.
Configure Agent Gateway (Control
Plane to Data Plane) at each cluster
for L7 Agent Gateway.","The single Control Plane successfully pushes
the configuration down to all Relay Agents /
Data Planes simultaneously.","Systems required: cluster1 + cluster2 kubeconfig contexts · istiod in istio-system (cluster1) · ztunnel DaemonSet in istio-system on both clusters · enterprise-agentgateway control plane in agentgateway-system (cluster1) · AgentGateway data plane pods on both clusters.

What is validated: (1) A single istiod pod on cluster1 is confirmed as the sole control plane, with ztunnel running on both clusters. (2) AgentGateway control plane (cluster1) manages AgentGateway data planes on both clusters. (3) An xDS config change (e.g. a new AuthorizationPolicy applied to cluster1) propagates to ztunnel on both clusters within the XDS sync window. (4) AgentGateway route and policy CRDs created on cluster1 are reflected in both data planes.

Net cluster change: none.","[AgentGateway observability — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/observability/) · [Phase7-ControlPlane-Registry-and-Mesh/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase7-ControlPlane-Registry-and-Mesh/validate.sh)"
CP-02 ,"Central Registry &
Health Checks","Register distributed tools via Agent
Registry. Gateway performs active
health checks on MCP servers.","Control Plane accurately reflects an
unhealthy server, logs it via OTEL, and
removes it from L7 discovery.","Systems required: cluster1 kubeconfig context · AgentRegistry in agentregistry namespace (port-forwarded to localhost:8080) · agentgateway-hub Service · mcp-server-everything Deployment in agentgateway-system.

What is validated: (1) GET /v0/servers shows all registered MCP servers and their current health status. (2) AgentGateway performs active health checks (HTTP HEAD or GET) against registered server URLs. (3) Scaling mcp-server-everything to 0 causes the AGW health check to fail. (4) The control plane marks the server as unhealthy and it is excluded from the L7 backend pool — tools/list from the affected route returns an empty or error response. (5) Server is restored and health check recovers.

Net cluster change: none (health check state is transient).","[AgentGateway observability — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/observability/) · [Phase7-ControlPlane-Registry-and-Mesh/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase7-ControlPlane-Registry-and-Mesh/validate.sh)"
CP-03,"Isolated Admin
Workspaces","Create Gloo Workspace CRDs,
bound via Kubernetes RBAC.","An Admin can view and configure only Plane
& MCP servers within its Workspace.","Systems required: cluster1 kubeconfig context · Gloo Mesh Enterprise management plane (Workspace CRDs) · ClusterRoleBindings scoped to workspace namespaces · At least two admin service accounts with different workspace bindings.

What is validated: (1) Workspace CRDs define namespace-scoped boundaries for Admin A and Admin B. (2) Admin A's kubeconfig (or service account) can only get/list HTTPRoute, AgentgatewayBackend, and EnterpriseAgentgatewayPolicy resources within their workspace namespace. (3) Admin A cannot get or list resources in Admin B's workspace namespace. (4) A Kubernetes RBAC check (kubectl auth can-i) confirms the isolation. Note: Workspace CRDs require Gloo Mesh Enterprise management plane; document the expected behavior if not deployed.

Net cluster change: none.","[AgentGateway observability — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/observability/) · [Phase7-ControlPlane-Registry-and-Mesh/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase7-ControlPlane-Registry-and-Mesh/validate.sh)"
CP-04 ,"Super Admin
Master Control","Log in to the Centralized AI team
(Super Admin) account.","The Super Admin has global cluster-scoped
visibility to cross administrative boundaries
and manage all Data Planes globally.","Systems required: cluster1 + cluster2 kubeconfig contexts · AgentRegistry in agentregistry namespace · agentgateway-hub + all data plane resources in agentgateway-system on both clusters · Super admin credentials (or service account with cluster-scoped RBAC).

What is validated: (1) GET /v0/servers on AgentRegistry returns all registered servers from all namespaces. (2) kubectl get httproute,agentgatewaybackend,enterpriseagentgatewaypolicy across both clusters shows all resources. (3) Super admin role (via ClusterRoleBinding) permits reading all resources cluster-wide. (4) Workspace-scoped admin cannot reproduce this global view — their API calls are rejected with 403 for out-of-workspace resources.

Net cluster change: none.","[AgentGateway observability — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/observability/) · [Phase7-ControlPlane-Registry-and-Mesh/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase7-ControlPlane-Registry-and-Mesh/validate.sh)"
CP-05,"OTEL Distributed
Tracing","Execute an MCP tools/call via the
gateway to a federated server. Open
Jaeger.","A single trace span maps the cross-cluster
journey. Metrics correctly label the tool
invocation and latency.","Systems required: cluster1 + cluster2 kubeconfig contexts · OTEL collector deployed and configured to receive traces from AgentGateway · Jaeger or Tempo backend for trace storage · agentgateway-hub Service with OTEL tracing enabled via EnterpriseAgentgatewayPolicy · mcp-server-everything on both clusters · netshoot pod in debug namespace.

What is validated: (1) A tools/call request is sent to the AGW hub at /mcp/remote (cross-cluster path). (2) The HTTP response includes a traceparent header (W3C Trace Context) containing a trace ID. (3) In Jaeger UI, searching for this trace ID shows a single distributed trace spanning: AGW Hub (cluster1) → HBONE tunnel → east-west GW → cluster2 ztunnel → MCP server. (4) Span labels include tool name, latency per hop, and cluster identity. This enables the platform team to pinpoint latency bottlenecks in any cross-cluster MCP call.

Net cluster change: none.","[OTEL observability stack — docs.solo.io](https://docs.solo.io/agentgateway/2.2.x/observability/otel-stack/) · [Phase7-ControlPlane-Registry-and-Mesh/validate.sh — GitHub](https://github.com/jamesilse-solo/agentgateway-multicluster-mcp-demo/blob/main/POC-Success-Criteria/Phase7-ControlPlane-Registry-and-Mesh/validate.sh)"