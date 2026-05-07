# Phase 5 — Identity & Access Control

> Validates **AUTH-01, AUTH-02, AUTH-03, AUTH-04** — the L7 identity model. The mesh layer (Phase 2) protects connections by SPIFFE identity. **This phase moves up the stack** to the JWT/OAuth layer where agent and user identities live, and where per-tool access decisions are made.

The customer's audience cares about three things in this phase:

1. **No agent-side auth code.** Agents present a token; the gateway validates it. MCP servers see a clean, authenticated request — they do not implement OAuth themselves.
2. **Per-tool access**, not per-server. A "support agent" can call `list_tickets` but not `delete_database` even if both live on the same MCP server.
3. **Verifiable on-behalf-of chains**. When an agent calls a SaaS tool on behalf of a user, the SaaS upstream sees a token derived from the user, not a long-lived service account.

## Tests in this phase

| ID | Requirement | What success proves | Net cluster change |
|----|-------------|---------------------|--------------------|
| AUTH-01 | OAuth 2.0 / OIDC at the Gateway | Missing or invalid token → 401 at the gateway. Valid token proceeds. MCP servers have zero auth code. | None |
| AUTH-02 | Tool-Level RBAC (OPA) | OPA Rego policy parses the JSON-RPC tool name + JWT claims. `delete_database` is blocked for `role: agent`, allowed for `role: admin`. | OPA ConfigMap + AuthConfig referenced (left in place; demo state) |
| AUTH-03 | Two-Level Tool Filtering | Filtering at server-level (which servers an agent can see) AND tool-level (which tools within a server). `tools/list` and `tools/call` reflect both layers. | Optional policy resources (ranged within the test) |
| AUTH-04 | Token Exchange / On-Behalf-Of | Gateway exchanges the agent's identity token for a downstream token (RFC 8693) bound to the upstream SaaS. Upstream sees a user-derived token, not a static credential. | None (test is read-only against an existing exchange config) |

## Run

```bash
KUBE_CONTEXT=cluster1 ./POC-Success-Criteria-v2/Phase5-Identity-and-Access/validate.sh
```

The script is interactive. AUTH-04 may print a "manual / read-only" note if token-exchange wiring isn't yet provisioned in the demo cluster — see caveats below.

## Prerequisites

| Component | Namespace | Why |
|-----------|-----------|-----|
| OIDC IdP (Dex for the demo cluster; production environments typically use Keycloak with Entra brokering or equivalent) | `dex` (demo) | issues JWTs |
| `ext-auth-service` pod | `agentgateway-system` | validates JWTs at the gateway |
| OPA policy ConfigMap | `agentgateway-system` | for AUTH-02 / AUTH-03 |
| `agentgateway-hub` external LB | — | endpoint under test |
| `netshoot` debug pod | `debug` | request originator (not strictly required if running curl locally with tokens) |
| Demo creds | — | `demo@example.com` / `demo-pass` / `agw-client` / `agw-client-secret` (Dex demo grant) |

## AUTH-01 — OAuth 2.0 / OIDC at the Gateway

### What we're proving

ExtAuth at the gateway is the single point where every JWT is validated — signature, expiry, issuer, audience. If validation fails, the gateway returns 401 and the MCP server never sees the request. The flip side: the MCP server can trust that any request it receives has already been authenticated.

### What the script does

1. Send a request to `agentgateway-hub` with **no token**. Expect HTTP 401.
2. Acquire a JWT from the IdP via the password grant (demo) or a real client-credentials grant (production).
3. Decode the JWT (locally) and show the `iss`, `aud`, `exp`, and `sub` claims so reviewers can see what was issued.
4. Send the same request with `Authorization: Bearer <jwt>`. Expect HTTP 200 (or whatever the MCP server returns for a well-formed call).
5. Tamper one character in the JWT and send again. Expect 401.

### What success looks like

- No-token: 401 — **or 302 redirect** if the gateway's ExtAuth is configured for browser/redirect flow (Dex/Entra OIDC providers commonly redirect unauthenticated requests to a login page rather than returning 401 directly). Both outcomes confirm "the request was rejected at the gateway" and are equivalent for this test.
- Valid token: passes through, MCP server returns a real response (HTTP 200/204).
- Tampered token: 401 or 302 (same as no-token — rejection at the gateway).
- ExtAuth pod log shows the validation outcome for each request.

### Caveat — 302 vs 401 in the demo cluster

The demo cluster's `oidc-dex` AuthConfig is set up for browser-style OIDC flow, so unauthenticated calls receive a 302 redirect to the Dex login page rather than a flat 401. Customers expecting machine-to-machine API behaviour will typically configure ExtAuth for `client-credentials` flow with direct 401 responses; the security guarantee (request rejected before reaching the MCP server) is identical either way.

## AUTH-02 — Tool-Level RBAC (OPA)

### What we're proving

Per-server RBAC ("you can use this MCP server") is too coarse. Real authorisation is per-tool: a user may call `list_tickets` but not `delete_ticket`, even though both live on the same server. With ExtAuth + OPA, a Rego policy parses the JSON-RPC body, extracts the tool name, evaluates it against JWT claims, and decides.

### What the script does

1. Confirm the OPA policy ConfigMap is in place and the `AuthConfig` references it.
2. Acquire JWT_A with `role: agent` (cannot delete).
3. Acquire JWT_B with `role: admin` (can delete).
4. From either JWT context, send `tools/call` with `name: echo` (always allowed). Expect success.
5. From JWT_A, send `tools/call` with `name: delete_database`. Expect MCP permission error.
6. From JWT_B, send the same. Expect success.

### What success looks like

- A's `delete_database` returns a JSON-RPC error with code `-32000` (or equivalent) and a permission message.
- B's `delete_database` returns a real result.
- OPA decision logs (if exposed) show the rule that matched.

### Caveats

- The demo cluster's OPA ConfigMap and the JWTs need to be aligned — if the demo IdP doesn't yet emit a `role` claim, the test prints the tweak required and falls back to a hand-crafted JWT to demonstrate the policy.

## AUTH-03 — Two-Level Tool Filtering

### What we're proving

Two tiers of filtering applied together:

- **Server-level filtering**: which MCP servers an agent identity can even see in `tools/list`. A "customer-support" agent might only see `support-tools`. A "platform" agent might see all servers.
- **Tool-level filtering**: which tools within an allowed server an agent can call. Within `support-tools`, the support agent might see `list_tickets` and `add_comment` but not `escalate_to_legal`.

This is exactly what the customer asked for in the 2026-04-30 sync — fine-grained least-privilege.

### What the script does

1. Apply a policy where:
   - `agent-A` (claim `team: support`) sees only `support-tools` and within it only `list_tickets` + `add_comment`.
   - `agent-B` (claim `team: platform`) sees all tools.
2. From agent-A, `tools/list` — confirm only `support-tools` appears, with the filtered tool list.
3. From agent-A, `tools/call` of `escalate_to_legal` — expect denial.
4. From agent-B, `tools/list` — confirm all servers and all tools appear.

### What success looks like

- Agent-A's `tools/list` is a strict subset of the full catalog.
- Agent-A's denied tool calls return MCP permission errors.
- Agent-B's `tools/list` is the full catalog.

### Caveats

- The mechanism may use a combination of `AgentgatewayBackend` selector labels (server-level) and OPA rego policy (tool-level). The exact wiring depends on what the demo cluster has applied; the test reflects whatever is in place and falls back to documenting the expected manifests if not yet present.

## AUTH-04 — Token Exchange / On-Behalf-Of

### What we're proving

When an agent calls a SaaS tool on behalf of a user, two things must hold:

1. The SaaS upstream gets a token that identifies the user (audit + per-user authorisation upstream).
2. The agent never sees the SaaS credentials — they live in the gateway's exchange flow.

The mechanism is **OAuth 2.0 Token Exchange (RFC 8693)**. The agent presents its own JWT. The gateway calls the IdP's token-exchange endpoint with the agent's JWT as the `subject_token`, requests a new token bound to the SaaS audience, and forwards the result upstream.

### What the script does

1. Confirm the IdP supports RFC 8693 (Keycloak ✓, Auth0 ✓, Entra ✓; Dex ✗ — see caveats).
2. Confirm the gateway's token-exchange `AuthConfig` is in place pointing at the IdP's exchange endpoint.
3. Acquire a baseline JWT for the agent (its own identity).
4. Make a tools/call to a SaaS-backed MCP server through the gateway.
5. Inspect the upstream service's request headers (via test endpoint or controlled mock SaaS) to confirm the upstream `Authorization` header carries a *different* token than the agent's original — and that the new token's `sub`/`act` claims encode the original agent identity.

### What success looks like

- Upstream sees a token with audience `aud=<saas-server>`, not the agent's original audience.
- The exchanged token's `act` claim (or equivalent) records the agent acting on behalf of the user.
- ExtAuth + IdP logs show the exchange call.

### Caveats

- Dex (used in the demo cluster's EKS environment) does **not** support token exchange. For this test, the EKS demo cluster will print a `note` and skip; running against the OCP cluster (Keycloak) gives a real result.
- Production environments using Keycloak (with Entra brokering or otherwise) or Auth0 support token exchange and pass this test.
- This test does NOT validate the SaaS server's behaviour with the exchanged token; that's an integration concern with the specific SaaS provider.

## What this phase deliberately does NOT cover

- **mTLS-only auth.** The gateway can also validate mTLS client certificates instead of JWTs; that's a different demo path, less relevant for AI agent flows where JWT is dominant.
- **DCR (Dynamic Client Registration).** Removed from the v2 list — Dex doesn't support it and most enterprise IdPs (Keycloak / Auth0 / Entra) cover the same need through admin-issued client credentials.
- **Per-tool rate limiting tied to identity.** Phase 6 covers global rate limiting; per-identity per-tool rate limits are an advanced extension not in this POC.
