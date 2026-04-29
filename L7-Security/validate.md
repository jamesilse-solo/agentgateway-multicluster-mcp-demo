# L7 Agent Gateway — Security, Identity & TBAC

Validates L7-SEC-01 through L7-SEC-06 on the Singtel POC clusters.

## Run

```bash
KUBE_CONTEXT=cluster1-singtel ./L7-Security/validate.sh
```

## Tests

| ID | Requirement | What it proves | Net cluster change |
|----|-------------|-----------------|-------------------|
| L7-SEC-01 | OAuth 2.0 (Client to Gateway) | Unauthenticated requests → 302/401; Dex JWT Bearer → 200 | None |
| L7-SEC-02 | Tool & Resource Level RBAC | OPA Rego policy evaluates JWT role claim against JSON-RPC tool name; non-admin blocked | None |
| L7-SEC-03 | Task-Based Access Control | OPA evaluates `task` JWT claim; tool calls outside authorized task scope are rejected | None |
| L7-SEC-04 | L7 Multi-Tenancy Support | HTTPRoute path/header match isolates tenants to their own backend pools | None |
| L7-SEC-05 | Dynamic Client Registration | Gateway triggers RFC 7591 DCR flow for unregistered clients (requires Keycloak/Auth0) | None |
| L7-SEC-06 | Upstream Gateway to Server Auth | Gateway injects upstream credentials before forwarding; agent never handles SaaS API keys | None |

## Prerequisites

| Component | Namespace | Check |
|-----------|-----------|-------|
| `cluster1-singtel` context | — | `kubectl config get-contexts cluster1-singtel` |
| Dex OIDC | `dex` | `kubectl --context cluster1-singtel -n dex get pod -l app=dex` |
| `oidc-dex` AuthConfig | `agentgateway-system` | `kubectl --context cluster1-singtel -n agentgateway-system get authconfig oidc-dex` |
| ExtAuth service | `agentgateway-system` | `kubectl --context cluster1-singtel -n agentgateway-system get pod -l app=ext-auth-service` |
| agentgateway-hub LB | `agentgateway-system` | `kubectl --context cluster1-singtel -n agentgateway-system get svc agentgateway-hub` |

**Note on L7-SEC-05:** Dynamic Client Registration requires an IdP that implements RFC 7591 (e.g. Keycloak, Auth0). Dex does not support DCR. For a full DCR demonstration, deploy Keycloak and reference `docs.solo.io/agentgateway/2.2.x/security/extauth/oauth/`.
