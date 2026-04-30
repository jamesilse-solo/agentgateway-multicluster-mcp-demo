#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 09-optional-components.sh — POC Coverage Gap Fillers
#
# Deploys the additional components required to fully prove the POC success
# criteria that the core installation scripts do not cover.
#
# Run all sections (default) or specific ones:
#   ./09-optional-components.sh                 # all sections
#   SECTIONS=1,4,6 ./09-optional-components.sh  # only egress, rate-limit, OTEL
#
# Sections:
#   1 — Istio Egress Gateway + REGISTRY_ONLY egress policy   (MESH-08, MESH-09)
#   2 — OPA Tool RBAC + Task-Based Access Control            (SEC-02, SEC-03)
#   3 — Upstream Credential Injection                        (SEC-06)
#   4 — Rate Limiting (RateLimitConfig, ext-cache already deployed)  (GR-03)
#   5 — ExtProc Guardrail Webhook (passthrough placeholder)  (GR-01)
#   6 — OTEL Collector + Jaeger + AGW tracing policy         (CP-05)
#   7 — Keycloak + Dynamic Client Registration  [OPTIONAL, HEAVY]  (SEC-05)
#
# Prerequisites:
#   - 01-install.sh, 02-configure.sh, 03-dex.sh, 05-extauth.sh complete
#   - agentgateway-hub Gateway exists in agentgateway-system
#   - AuthConfig oidc-dex exists (created by 05-extauth.sh)
#   - helm, kubectl, istioctl available on PATH
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NS="${AGW_NS:-agentgateway-system}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.1}"
ISTIO_HELM_REPO="${ISTIO_HELM_REPO:-us-docker.pkg.dev/soloio-img/istio-helm}"
AGW_HELM_REPO="${AGW_HELM_REPO:-us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts}"
AGW_VERSION="${AGW_VERSION:-v2.3.0-rc.3}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin-secret-change-me}"
SECTIONS="${SECTIONS:-1,2,3,4,5,6}"   # Section 7 (Keycloak) is opt-in only

KC="kubectl --context ${KUBE_CONTEXT}"
log()  { echo ""; echo "=== $* ==="; }
ok()   { echo "  ✅  $*"; }
warn() { echo "  ⚠️   $*"; }

run_section() {
  local n="$1"
  [[ ",${SECTIONS}," == *",${n},"* ]]
}

###############################################################################
# SECTION 1 — Istio Egress Gateway + REGISTRY_ONLY egress policy
# Proves: MESH-08 (centralized SaaS egress), MESH-09 (exfiltration cage)
###############################################################################
if run_section 1; then
  log "SECTION 1 — Istio Egress Gateway + REGISTRY_ONLY"

  # 1a — Deploy egress gateway as an additional Helm release
  # The egress gateway runs as a separate pod from the east-west gateway.
  log "1a: Installing Istio egress gateway"
  helm upgrade --install istio-egressgateway \
    "oci://${ISTIO_HELM_REPO}/gateway" \
    --namespace istio-system \
    --create-namespace \
    --version "${ISTIO_VERSION}" \
    --set labels.istio=egressgateway \
    --set labels.app=istio-egressgateway \
    --set service.type=LoadBalancer \
    --set networkGateway="" \
    --wait --timeout 120s

  ${KC} -n istio-system rollout status deploy/istio-egressgateway --timeout=120s
  ok "Egress gateway deployed"

  EGW_IP=$(${KC} -n istio-system get svc istio-egressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || echo "pending")
  ok "Egress gateway address: ${EGW_IP}"

  # 1b — ServiceEntry for the reference SaaS tool (search.solo.io)
  # Register the external hostname in the mesh service registry so that
  # VirtualService rules can route it through the egress gateway.
  log "1b: ServiceEntry for search.solo.io (reference SaaS MCP tool)"
  ${KC} apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: search-solo-io
  namespace: ${AGW_NS}
spec:
  hosts:
  - search.solo.io
  ports:
  - number: 443
    name: https
    protocol: HTTPS
  location: MESH_EXTERNAL
  resolution: DNS
EOF
  ok "ServiceEntry for search.solo.io created"

  # 1c — Gateway resource on the egress gateway for the SaaS host
  log "1c: Egress Gateway resource for search.solo.io"
  ${KC} apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: egress-saas-gateway
  namespace: ${AGW_NS}
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH
    hosts:
    - search.solo.io
EOF

  # 1d — VirtualService: route search.solo.io through the egress gateway
  log "1d: VirtualService routing search.solo.io via egress gateway"
  ${KC} apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: egress-route-search-solo
  namespace: ${AGW_NS}
spec:
  hosts:
  - search.solo.io
  gateways:
  - mesh
  - egress-saas-gateway
  tls:
  - match:
    - gateways:
      - mesh
      port: 443
      sniHosts:
      - search.solo.io
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        port:
          number: 443
  - match:
    - gateways:
      - egress-saas-gateway
      port: 443
      sniHosts:
      - search.solo.io
    route:
    - destination:
        host: search.solo.io
        port:
          number: 443
EOF
  ok "VirtualService for egress routing applied"

  # 1e — Set outboundTrafficPolicy: REGISTRY_ONLY in the Istio mesh config.
  # This blocks traffic to any host not registered via ServiceEntry.
  # WARNING: this is a cluster-wide change. Ensure all required external
  # hosts have ServiceEntries before enabling (httpbin.org will be blocked).
  log "1e: Setting outboundTrafficPolicy: REGISTRY_ONLY in mesh config"
  warn "This is a CLUSTER-WIDE change. All external hosts not in a ServiceEntry will be blocked."
  warn "Add ServiceEntries for any other external endpoints BEFORE running this step."
  warn "To skip, run: SECTIONS=1 but comment out step 1e"

  MESH_CONFIG=$(${KC} -n istio-system get cm istio \
    -o jsonpath='{.data.mesh}' 2>/dev/null || echo "")

  if echo "${MESH_CONFIG}" | grep -q "REGISTRY_ONLY"; then
    ok "outboundTrafficPolicy: REGISTRY_ONLY already set"
  else
    ${KC} -n istio-system get cm istio -o json \
      | python3 -c "
import sys, json
cm = json.load(sys.stdin)
mesh = cm['data'].get('mesh', '')
if 'outboundTrafficPolicy' not in mesh:
    mesh = mesh.rstrip() + '\noutboundTrafficPolicy:\n  mode: REGISTRY_ONLY\n'
cm['data']['mesh'] = mesh
print(json.dumps(cm))
" | ${KC} apply -f -
    ok "outboundTrafficPolicy: REGISTRY_ONLY patched into mesh configmap"
    warn "Restart istiod to pick up the change: ${KC} -n istio-system rollout restart deploy/istiod"
  fi
fi

###############################################################################
# SECTION 2 — OPA Tool RBAC + Task-Based Access Control (TBAC)
# Proves: SEC-02 (tool-level RBAC), SEC-03 (task context authorization)
###############################################################################
if run_section 2; then
  log "SECTION 2 — OPA Tool RBAC + TBAC"

  # 2a — OPA policy ConfigMap: tool-level RBAC
  # The policy checks the caller's JWT 'role' claim against an allowed-tools
  # map. Admins can call any tool; agents are restricted to safe tools.
  log "2a: OPA ConfigMap — tool-level RBAC (SEC-02)"
  ${KC} apply -n "${AGW_NS}" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: opa-tool-rbac
  namespace: agentgateway-system
data:
  tool_rbac.rego: |
    package agw

    import future.keywords.in

    default allow = false

    # Allow the request if the caller's role permits the requested tool.
    allow {
        claims := jwt_claims
        tool_name := jsonrpc_tool_name
        allowed_tools_for_role[claims.role][_] == tool_name
    }

    # Allow non-tools/call methods (initialize, tools/list, etc.) unconditionally.
    allow {
        method := json.unmarshal(input.http_request.body).method
        method != "tools/call"
    }

    jwt_claims := payload {
        auth_header := input.http_request.headers["authorization"]
        startswith(auth_header, "Bearer ")
        token := substring(auth_header, 7, -1)
        [_, payload, _] := io.jwt.decode(token)
    }

    jsonrpc_tool_name := name {
        body := json.unmarshal(input.http_request.body)
        name := body.params.name
    }

    allowed_tools_for_role := {
        "admin":  {"echo", "delete_database", "list_files", "read_file", "write_file"},
        "agent":  {"echo", "list_files", "read_file"},
        "viewer": {"echo"},
    }
EOF
  ok "OPA tool RBAC ConfigMap created"

  # 2b — OPA policy ConfigMap: Task-Based Access Control (TBAC)
  # The policy maps task context claims to allowed tool sets. An agent
  # presenting task=customer-support cannot call infrastructure tools
  # even if it has role=agent.
  log "2b: OPA ConfigMap — TBAC (SEC-03)"
  ${KC} apply -n "${AGW_NS}" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: opa-tbac
  namespace: agentgateway-system
data:
  tbac.rego: |
    package agw_tbac

    import future.keywords.in

    default allow = false

    # Allow if the agent's task claim authorizes the requested tool.
    allow {
        claims := jwt_claims
        task   := claims.task
        tool   := jsonrpc_tool_name
        allowed_tools_for_task[task][_] == tool
    }

    # Allow non-tools/call methods unconditionally.
    allow {
        method := json.unmarshal(input.http_request.body).method
        method != "tools/call"
    }

    # If no task claim is present, fall back to role-based check.
    allow {
        not jwt_claims.task
    }

    jwt_claims := payload {
        auth_header := input.http_request.headers["authorization"]
        startswith(auth_header, "Bearer ")
        token := substring(auth_header, 7, -1)
        [_, payload, _] := io.jwt.decode(token)
    }

    jsonrpc_tool_name := name {
        body := json.unmarshal(input.http_request.body)
        name := body.params.name
    }

    allowed_tools_for_task := {
        "customer-support":   {"echo", "list_files", "read_file"},
        "infra-automation":   {"echo", "list_files", "read_file", "write_file", "delete_database"},
        "analytics-pipeline": {"echo", "list_files", "read_file"},
    }
EOF
  ok "OPA TBAC ConfigMap created"

  # 2c — Update AuthConfig to chain OIDC → OPA RBAC → OPA TBAC
  # The existing oidc-dex AuthConfig is updated to add the two OPA
  # modules as subsequent config steps. All three must pass.
  log "2c: Patching AuthConfig oidc-dex to add OPA configs"
  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: oidc-with-opa
  namespace: ${AGW_NS}
spec:
  configs:
  - oauth2:
      oidcAuthorizationCode:
        appUrl: "http://$(${KC} -n ${AGW_NS} get svc agentgateway-hub \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
        callbackPath: /callback
        clientId: agw-client
        clientSecretRef:
          name: oauth-dex
          namespace: ${AGW_NS}
        issuerUrl: "http://dex.dex.svc.cluster.local:5556/dex/"
        scopes:
        - openid
        - email
        - profile
        session:
          failOnFetchFailure: true
          redis:
            cookieName: dex-session
            options:
              host: ext-cache-enterprise-agentgateway:6379
        headers:
          idTokenHeader: x-user-token
  - opaAuth:
      modules:
      - name: opa-tool-rbac
        namespace: ${AGW_NS}
      query: "data.agw.allow == true"
  - opaAuth:
      modules:
      - name: opa-tbac
        namespace: ${AGW_NS}
      query: "data.agw_tbac.allow == true"
EOF

  # Update the EnterpriseAgentgatewayPolicy to reference the combined AuthConfig
  log "Updating EnterpriseAgentgatewayPolicy to use oidc-with-opa"
  ${KC} patch enterpriseagentgatewaypolicy oidc-extauth \
    -n "${AGW_NS}" \
    --type='merge' \
    -p "{\"spec\":{\"traffic\":{\"entExtAuth\":{\"authConfigRef\":{\"name\":\"oidc-with-opa\",\"namespace\":\"${AGW_NS}\"}}}}}"

  ok "AuthConfig updated with OPA RBAC + TBAC"
  warn "Restart ext-auth-service to pick up new OPA modules:"
  warn "  ${KC} -n ${AGW_NS} rollout restart deploy/ext-auth-service-enterprise-agentgateway"
fi

###############################################################################
# SECTION 3 — Upstream Credential Injection
# Proves: SEC-06 (gateway injects upstream API key; agent never sees it)
###############################################################################
if run_section 3; then
  log "SECTION 3 — Upstream Credential Injection (SEC-06)"

  # 3a — Store the upstream service credential as a Kubernetes Secret.
  # In production this would be a real SaaS API key (Jira, Slack, etc.).
  log "3a: Creating upstream API key Secret"
  ${KC} apply -n "${AGW_NS}" -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: upstream-saas-apikey
  namespace: agentgateway-system
type: Opaque
stringData:
  api-key: "demo-upstream-api-key-replace-in-production"
EOF
  ok "Upstream API key secret created"

  # 3b — Create a header-injection AuthConfig that adds the upstream
  # Authorization header before forwarding to the MCP server.
  # This AuthConfig is applied after the OIDC check passes.
  log "3b: Creating upstream credential injection AuthConfig"
  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: upstream-credential-injector
  namespace: ${AGW_NS}
spec:
  configs:
  - pluginAuth:
      name: upstream-credential-injection
      config:
        "@type": "type.googleapis.com/google.protobuf.Struct"
        value:
          injectHeaders:
          - header: "x-upstream-api-key"
            secretRef:
              name: upstream-saas-apikey
              namespace: ${AGW_NS}
              key: api-key
EOF

  # 3c — EnterpriseAgentgatewayPolicy scoped to the remote (SaaS) route
  # to inject the upstream credential only on that path.
  log "3c: EnterpriseAgentgatewayPolicy for upstream credential injection"
  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: upstream-credential-injection
  namespace: ${AGW_NS}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: mcp-route
    namespace: ${AGW_NS}
  traffic:
    entExtAuth:
      authConfigRef:
        name: upstream-credential-injector
        namespace: ${AGW_NS}
      backendRef:
        name: ext-auth-service-enterprise-agentgateway
        namespace: ${AGW_NS}
        port: 8083
EOF
  ok "Upstream credential injection policy applied"
  warn "Replace 'demo-upstream-api-key-replace-in-production' in the secret with a real key"
fi

###############################################################################
# SECTION 4 — Rate Limiting
# Proves: GR-03 (per-agent request cap; runaway agent loop prevention)
# Note: ext-cache (Redis) is already deployed with AGW Enterprise.
###############################################################################
if run_section 4; then
  log "SECTION 4 — Rate Limiting (GR-03)"

  # 4a — Verify ext-cache (Redis) is running
  log "4a: Verifying ext-cache (Redis) is available"
  ${KC} -n "${AGW_NS}" get pod -l app=ext-cache 2>/dev/null \
    | grep -E "Running|NAME" \
    && ok "ext-cache Redis is running" \
    || warn "ext-cache not found — rate limiting requires Redis (check AGW install)"

  # 4b — RateLimitConfig: 10 requests per minute per agent identity
  # The limit is keyed on the x-user-token header (the JWT email claim
  # extracted by ExtAuth). Each unique agent gets its own counter.
  log "4b: Creating RateLimitConfig (10 rpm per agent)"
  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: ratelimit.solo.io/v1alpha1
kind: RateLimitConfig
metadata:
  name: mcp-per-agent-limit
  namespace: ${AGW_NS}
spec:
  raw:
    setDescriptors:
    - simpleDescriptors:
      - key: x-agent-id
      rateLimit:
        requestsPerUnit: 10
        unit: MINUTE
    rateLimits:
    - setActions:
      - requestHeaders:
          headerName: x-user-token
          descriptorKey: x-agent-id
EOF
  ok "RateLimitConfig created (10 rpm per agent JWT)"

  # 4c — Add rate limit reference to the existing gateway policy
  # Patching the oidc-extauth policy to also enforce rate limits.
  log "4c: Patching EnterpriseAgentgatewayPolicy with rate limit"
  ${KC} patch enterpriseagentgatewaypolicy oidc-extauth \
    -n "${AGW_NS}" \
    --type='merge' \
    -p "{\"spec\":{\"traffic\":{\"rateLimit\":{\"rateLimitConfigRef\":{\"name\":\"mcp-per-agent-limit\",\"namespace\":\"${AGW_NS}\"}}}}}"
  ok "Rate limit attached to gateway policy"

  warn "Rate limit server must be enabled in the AGW Helm values:"
  warn "  rateLimitServer.enabled: true"
  warn "  rateLimitServer.rateLimitService.host: ext-cache-enterprise-agentgateway"
fi

###############################################################################
# SECTION 5 — ExtProc Guardrail Webhook (GR-01)
# Proves: GR-01 (every MCP payload inspected by an external guardrail)
#
# Production deployment: replace the placeholder with F5 AI Gateway (Calypso)
# or a custom gRPC service implementing envoy.service.ext_proc.v3.ExternalProcessor.
# The placeholder below demonstrates the wiring only.
###############################################################################
if run_section 5; then
  log "SECTION 5 — ExtProc Guardrail Webhook (GR-01)"

  # 5a — Deploy a minimal passthrough ExtProc service.
  # This Python service implements the Envoy ext_proc gRPC protocol and
  # passes requests through unmodified. Replace it with a real PII scrubber
  # or content policy engine in production.
  log "5a: Deploying passthrough ExtProc service"
  ${KC} apply -n "${AGW_NS}" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ext-proc-server
  namespace: agentgateway-system
data:
  server.py: |
    #!/usr/bin/env python3
    """Minimal passthrough ExtProc — replace with real guardrail in production."""
    import grpc
    import logging
    import sys
    from concurrent import futures

    try:
        from envoy.service.ext_proc.v3 import external_processor_pb2 as pb
        from envoy.service.ext_proc.v3 import external_processor_pb2_grpc as pb_grpc
    except ImportError:
        logging.error("envoy-data-plane package not found. Install: pip install envoy-data-plane")
        sys.exit(1)

    logging.basicConfig(level=logging.INFO)
    log = logging.getLogger("ext-proc")

    class PassthroughExtProc(pb_grpc.ExternalProcessorServicer):
        def Process(self, request_iterator, context):
            for req in request_iterator:
                log.info("ext_proc: processing %s", req.WhichOneof("request"))
                resp = pb.ProcessingResponse()
                if req.HasField("request_headers"):
                    resp.request_headers.CopyFrom(pb.HeadersResponse())
                elif req.HasField("request_body"):
                    resp.request_body.CopyFrom(pb.BodyResponse())
                elif req.HasField("response_headers"):
                    resp.response_headers.CopyFrom(pb.HeadersResponse())
                elif req.HasField("response_body"):
                    resp.response_body.CopyFrom(pb.BodyResponse())
                yield resp

    if __name__ == "__main__":
        server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
        pb_grpc.add_ExternalProcessorServicer_to_server(PassthroughExtProc(), server)
        server.add_insecure_port("[::]:9001")
        server.start()
        log.info("ExtProc passthrough listening on :9001")
        server.wait_for_termination()
EOF

  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ext-proc-guardrail
  namespace: ${AGW_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ext-proc-guardrail
  template:
    metadata:
      labels:
        app: ext-proc-guardrail
    spec:
      containers:
      - name: ext-proc
        image: python:3.12-slim
        command: ["/bin/sh", "-c"]
        args:
        - pip install grpcio envoy-data-plane --quiet && python /app/server.py
        ports:
        - containerPort: 9001
          name: grpc
        volumeMounts:
        - name: code
          mountPath: /app
        readinessProbe:
          tcpSocket:
            port: 9001
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: code
        configMap:
          name: ext-proc-server
---
apiVersion: v1
kind: Service
metadata:
  name: ext-proc-guardrail
  namespace: ${AGW_NS}
spec:
  selector:
    app: ext-proc-guardrail
  ports:
  - name: grpc
    port: 9001
    targetPort: 9001
    protocol: TCP
EOF
  ok "ExtProc passthrough Deployment + Service created"

  # 5b — GatewayExtension pointing to the ExtProc service
  log "5b: Creating GatewayExtension"
  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: GatewayExtension
metadata:
  name: pii-guardrail
  namespace: ${AGW_NS}
spec:
  extProc:
    grpcService:
      backendRef:
        name: ext-proc-guardrail
        namespace: ${AGW_NS}
        port: 9001
    processingMode:
      requestHeaderMode: SEND
      requestBodyMode: BUFFERED
      responseHeaderMode: SEND
      responseBodyMode: NONE
EOF
  ok "GatewayExtension 'pii-guardrail' created"

  # 5c — EnterpriseAgentgatewayPolicy to wire the extension to the gateway
  log "5c: Attaching GatewayExtension to agentgateway-hub"
  ${KC} patch enterpriseagentgatewaypolicy oidc-extauth \
    -n "${AGW_NS}" \
    --type='merge' \
    -p '{"spec":{"traffic":{"extProc":{"extensionRef":{"name":"pii-guardrail"}}}}}'
  ok "ExtProc wired to gateway policy"
  warn "Replace the passthrough ExtProc container with F5 AI Gateway / Calypso for production PII scrubbing"
fi

###############################################################################
# SECTION 6 — OTEL Collector + Jaeger + AGW tracing policy
# Proves: CP-05 (cross-cluster distributed trace with traceparent header)
###############################################################################
if run_section 6; then
  log "SECTION 6 — OTEL Collector + Jaeger (CP-05)"

  # 6a — Add Helm repos
  log "6a: Adding OTEL + Jaeger Helm repos"
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
  helm repo add jaegertracing   https://jaegertracing.github.io/helm-charts 2>/dev/null || true
  helm repo update

  # 6b — Deploy Jaeger all-in-one (in-memory, suitable for POC)
  # In production, use jaeger-operator or a backend with persistent storage.
  log "6b: Deploying Jaeger all-in-one"
  helm upgrade --install jaeger jaegertracing/jaeger \
    --namespace "${AGW_NS}" \
    --set allInOne.enabled=true \
    --set collector.enabled=false \
    --set query.enabled=false \
    --set agent.enabled=false \
    --set storage.type=memory \
    --set allInOne.image.tag="1.57.0" \
    --wait --timeout 120s
  ok "Jaeger deployed"

  # 6c — Deploy OTEL Collector (receives from AGW, forwards to Jaeger)
  log "6c: Deploying OTEL Collector"
  helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
    --namespace "${AGW_NS}" \
    --set mode=deployment \
    --set image.repository=otel/opentelemetry-collector-contrib \
    --set image.tag=0.100.0 \
    --set config.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317" \
    --set config.receivers.otlp.protocols.http.endpoint="0.0.0.0:4318" \
    --set config.exporters.otlp.endpoint="jaeger-allInOne:4317" \
    --set config.exporters.otlp.tls.insecure=true \
    --set "config.service.pipelines.traces.receivers[0]=otlp" \
    --set "config.service.pipelines.traces.exporters[0]=otlp" \
    --wait --timeout 120s
  ok "OTEL Collector deployed"

  # 6d — EnterpriseAgentgatewayPolicy: enable OTEL tracing on the hub gateway
  log "6d: Enabling OTEL tracing via EnterpriseAgentgatewayPolicy"
  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: otel-tracing
  namespace: ${AGW_NS}
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: agentgateway-hub
  telemetry:
    openTelemetry:
      grpcService:
        backendRef:
          name: otel-collector-opentelemetry-collector
          namespace: ${AGW_NS}
          port: 4317
      serviceName: agentgateway
      resourceAttributes:
        cluster: ${KUBE_CONTEXT}
EOF
  ok "OTEL tracing policy applied"

  JAEGER_POD=$(${KC} -n "${AGW_NS}" get pod -l app.kubernetes.io/name=jaeger \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${JAEGER_POD}" ]]; then
    ok "Jaeger UI: ${KC} -n ${AGW_NS} port-forward pod/${JAEGER_POD} 16686:16686"
    ok "            then open http://localhost:16686 — search service: agentgateway"
  fi
fi

###############################################################################
# SECTION 7 — Keycloak + Dynamic Client Registration  [OPTIONAL / HEAVY]
# Proves: SEC-05 (RFC 7591 DCR — Dex does not support this protocol)
#
# This section is intentionally excluded from the default SECTIONS list.
# Run explicitly with: SECTIONS=7 ./09-optional-components.sh
###############################################################################
if run_section 7; then
  log "SECTION 7 — Keycloak + Dynamic Client Registration (SEC-05)"
  warn "This section deploys Keycloak (~2 min). Ensure cluster has sufficient resources."

  # 7a — Add Bitnami repo and deploy Keycloak
  log "7a: Deploying Keycloak"
  helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  helm repo update

  helm upgrade --install keycloak bitnami/keycloak \
    --namespace "${KEYCLOAK_NAMESPACE}" \
    --create-namespace \
    --set auth.adminUser=admin \
    --set auth.adminPassword="${KEYCLOAK_ADMIN_PASSWORD}" \
    --set postgresql.enabled=true \
    --set service.type=ClusterIP \
    --wait --timeout 300s
  ok "Keycloak deployed in namespace ${KEYCLOAK_NAMESPACE}"

  # 7b — Port-forward Keycloak admin console for realm configuration
  KC_SVC=$(${KC} -n "${KEYCLOAK_NAMESPACE}" get svc -l app.kubernetes.io/name=keycloak \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "keycloak")

  log "7b: Keycloak realm + DCR client configuration"
  warn "Automated realm creation requires the Keycloak admin REST API or kcadm."
  warn "Manual steps (or run after port-forwarding to localhost:8080):"
  echo ""
  echo "  1. Port-forward: ${KC} -n ${KEYCLOAK_NAMESPACE} port-forward svc/${KC_SVC} 8080:80 &"
  echo "  2. Login to admin console: http://localhost:8080/admin  (admin / ${KEYCLOAK_ADMIN_PASSWORD})"
  echo "  3. Create realm: agw-realm"
  echo "  4. In agw-realm → Clients → Client Registration → Anonymous access policies:"
  echo "     Enable 'Trusted Hosts' or set an initial access token"
  echo "  5. Test DCR: POST http://localhost:8080/realms/agw-realm/clients-registrations/openid-connect"
  echo "     -H 'Content-Type: application/json'"
  echo "     -d '{\"client_name\": \"my-mcp-client\", \"redirect_uris\": [\"http://localhost/callback\"]}'"
  echo "  6. The response contains a new client_id + client_secret (RFC 7591 compliant)"
  echo ""

  # 7c — AuthConfig for Keycloak OIDC (alongside the existing Dex AuthConfig)
  log "7c: Creating AuthConfig for Keycloak OIDC (for DCR flow)"
  KEYCLOAK_SVC_IP=$(${KC} -n "${KEYCLOAK_NAMESPACE}" get svc "${KC_SVC}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local")
  KEYCLOAK_ISSUER="http://${KEYCLOAK_SVC_IP}/realms/agw-realm"

  ${KC} apply -n "${AGW_NS}" -f - <<EOF
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: oidc-keycloak-dcr
  namespace: ${AGW_NS}
spec:
  configs:
  - oauth2:
      oidcAuthorizationCode:
        appUrl: "http://$(${KC} -n ${AGW_NS} get svc agentgateway-hub \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' \
          2>/dev/null)"
        callbackPath: /callback-keycloak
        clientId: agw-gateway-client
        clientSecretRef:
          name: oauth-keycloak
          namespace: ${AGW_NS}
        issuerUrl: "${KEYCLOAK_ISSUER}/"
        scopes:
        - openid
        - email
        - profile
        session:
          failOnFetchFailure: true
          redis:
            cookieName: keycloak-session
            options:
              host: ext-cache-enterprise-agentgateway:6379
        headers:
          idTokenHeader: x-user-token
EOF

  ok "Keycloak AuthConfig created"
  warn "Create a client 'agw-gateway-client' in the agw-realm Keycloak realm and store"
  warn "its secret in a Kubernetes secret named 'oauth-keycloak' before activating this AuthConfig."
  warn "Route DCR-capable paths to this AuthConfig via a new EnterpriseAgentgatewayPolicy."
fi

###############################################################################
# Done
###############################################################################
echo ""
echo "==================================================="
echo "  09-optional-components.sh complete"
echo ""
echo "  Components installed (depending on SECTIONS run):"
echo "  1 — Egress gateway + REGISTRY_ONLY       MESH-08, MESH-09"
echo "  2 — OPA RBAC + TBAC                      SEC-02, SEC-03"
echo "  3 — Upstream credential injection        SEC-06"
echo "  4 — Rate limiting (RateLimitConfig)      GR-03"
echo "  5 — ExtProc guardrail (placeholder)      GR-01"
echo "  6 — OTEL Collector + Jaeger              CP-05"
echo "  7 — Keycloak + DCR (if SECTIONS=7)       SEC-05"
echo "==================================================="
echo ""
