#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 09b-extproc-guardrails.sh — Real ExtProc guardrail (Nikhil's 5/18 asks)
#
# Replaces the passthrough placeholder in 09-optional-components.sh with a
# Python ExtProc that does TWO things on every MCP request body:
#
#   1. SCHEMA VALIDATION — hardcoded JSON schemas for known tools.
#      Rejects tools/call with extra, missing, or wrong-typed arguments.
#      Closes Biraj's specific ask: "block when agent sends 3-4 params
#      for a 2-param tool".
#
#   2. REGEX CONTENT GUARDRAILS — blocks bodies containing SSN, credit-card,
#      prompt-injection markers ("ignore previous instructions",
#      "<|im_start|>"), or exfiltration markers ("exfiltrate"). Closes
#      Nikhil's defense-in-depth ask.
#
# Both checks happen BEFORE the upstream MCP server is touched. On a
# block, the gateway returns HTTP 400 with a JSON-RPC -32602 error.
#
# Wire-up: GatewayExtension `mcp-guardrails` points at the ExtProc gRPC
# service; the oidc-extauth EnterpriseAgentgatewayPolicy gets a merge
# patch adding extProc.extensionRef. This applies to ALL MCP routes
# already covered by oidc-extauth.
#
# Prerequisites:
#   - 02-configure.sh + 05-extauth.sh have run
#
# Usage:
#   ./scripts/09b-extproc-guardrails.sh
#   ./scripts/09b-extproc-guardrails.sh --cleanup
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

if [[ "${1:-}" == "--cleanup" ]]; then
  log "Removing ExtProc guardrail"
  # Unwire from policy first
  ${KC} -n "${AGW_NAMESPACE}" get enterpriseagentgatewaypolicy oidc-extauth -o json 2>/dev/null \
    | jq 'del(.spec.traffic.extProc)' \
    | ${KC} apply -f - 2>/dev/null || true
  ${KC} -n "${AGW_NAMESPACE}" delete gatewayextension mcp-guardrails --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete svc ext-proc-guardrail --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete deploy ext-proc-guardrail --ignore-not-found
  ${KC} -n "${AGW_NAMESPACE}" delete configmap ext-proc-guardrail --ignore-not-found
  echo "✓ ExtProc guardrail removed"
  exit 0
fi

###############################################################################
# 1. ConfigMap with the Python ExtProc server
###############################################################################
log "Creating ExtProc ConfigMap"

SERVER_PY=$(cat <<'PY'
"""MCP ExtProc guardrail — schema validation + regex content policy."""
import json, logging, re, sys
from concurrent import futures

try:
    import grpc
    from envoy.service.ext_proc.v3 import external_processor_pb2 as pb
    from envoy.service.ext_proc.v3 import external_processor_pb2_grpc as pb_grpc
except ImportError as e:
    print(f"missing deps: {e}. install: pip install grpcio envoy-data-plane")
    sys.exit(1)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ext-proc")

# ----- Schema definitions for known MCP tools ------------------------------
# Edit this dict to add coverage for more tools. Wider/narrower than upstream
# is fine — this is a defense-in-depth check before the upstream sees the call.
TOOL_SCHEMAS = {
    "echo":    {"message": (str,)},
    "get-sum": {"a": (int, float), "b": (int, float)},
}

# ----- Content-policy regex patterns (request bodies) ----------------------
PATTERNS = [
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),               "PII:SSN"),
    (re.compile(r"\b(?:\d[ -]?){13,16}\b"),              "PII:credit-card"),
    (re.compile(r"(?i)ignore (all )?previous instructions"), "prompt-injection"),
    (re.compile(r"<\|im_start\|>|<\|system\|>"),         "prompt-injection-marker"),
    (re.compile(r"(?i)exfiltrate|exfil-?data"),          "exfiltration"),
]


def check_body(raw_bytes):
    """Return (blocked: bool, reason: str|None)."""
    try:
        body = raw_bytes.decode("utf-8", errors="replace")
    except Exception:
        return False, None

    # 1. Regex content scan on the raw body
    for pat, label in PATTERNS:
        if pat.search(body):
            return True, f"content policy ({label})"

    # 2. JSON-RPC schema check
    try:
        obj = json.loads(body)
    except Exception:
        return False, None

    if not isinstance(obj, dict):
        return False, None
    if obj.get("method") == "tools/call":
        params = obj.get("params", {}) or {}
        name = params.get("name")
        args = params.get("arguments", {}) or {}
        if name in TOOL_SCHEMAS:
            schema = TOOL_SCHEMAS[name]
            extra   = [k for k in args if k not in schema]
            missing = [k for k in schema if k not in args]
            if extra:
                return True, f"schema: tool '{name}' has unexpected param(s): {extra}"
            if missing:
                return True, f"schema: tool '{name}' missing param(s): {missing}"
            for k, expected_types in schema.items():
                if not isinstance(args[k], expected_types):
                    return True, f"schema: tool '{name}' param '{k}' has wrong type"
    return False, None


def make_block_response(reason):
    """Build an ImmediateResponse with a JSON-RPC error body."""
    imm = pb.ImmediateResponse()
    imm.status.code = 400
    payload = {
        "jsonrpc": "2.0",
        "id": None,
        "error": {"code": -32602, "message": f"blocked by gateway guardrail ({reason})"},
    }
    imm.body = json.dumps(payload).encode()
    h = imm.headers.set_headers.add()
    h.header.key = "content-type"
    h.header.raw_value = b"application/json"
    return imm


class GuardExtProc(pb_grpc.ExternalProcessorServicer):
    def Process(self, request_iterator, context):
        for req in request_iterator:
            resp = pb.ProcessingResponse()
            if req.HasField("request_headers"):
                resp.request_headers.CopyFrom(pb.HeadersResponse())
            elif req.HasField("request_body"):
                body = req.request_body.body
                blocked, reason = check_body(body)
                if blocked:
                    log.info("BLOCKED: %s", reason)
                    resp.immediate_response.CopyFrom(make_block_response(reason))
                else:
                    resp.request_body.CopyFrom(pb.BodyResponse())
            elif req.HasField("response_headers"):
                resp.response_headers.CopyFrom(pb.HeadersResponse())
            elif req.HasField("response_body"):
                resp.response_body.CopyFrom(pb.BodyResponse())
            yield resp


if __name__ == "__main__":
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    pb_grpc.add_ExternalProcessorServicer_to_server(GuardExtProc(), server)
    server.add_insecure_port("0.0.0.0:9001")
    server.start()
    log.info("ext-proc guardrail listening on :9001 (schema + regex)")
    server.wait_for_termination()
PY
)

${KC} -n "${AGW_NAMESPACE}" create configmap ext-proc-guardrail \
  --from-literal=server.py="${SERVER_PY}" \
  --dry-run=client -o yaml | ${KC} apply -f -

###############################################################################
# 2. Deployment + Service
###############################################################################
log "Deploying ExtProc guardrail pod"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ext-proc-guardrail
  namespace: agentgateway-system
spec:
  replicas: 1
  selector:
    matchLabels: { app: ext-proc-guardrail }
  template:
    metadata:
      labels: { app: ext-proc-guardrail }
    spec:
      containers:
      - name: ext-proc
        image: python:3.12-slim
        command: ["/bin/sh", "-c"]
        args:
        - pip install --quiet grpcio envoy-data-plane && python /app/server.py
        ports:
        - { containerPort: 9001, name: grpc }
        readinessProbe:
          tcpSocket: { port: 9001 }
          initialDelaySeconds: 30
          periodSeconds: 5
        volumeMounts:
        - { name: code, mountPath: /app }
      volumes:
      - name: code
        configMap:
          name: ext-proc-guardrail
          items: [{ key: server.py, path: server.py }]
---
apiVersion: v1
kind: Service
metadata:
  name: ext-proc-guardrail
  namespace: agentgateway-system
spec:
  selector: { app: ext-proc-guardrail }
  ports:
  - { name: grpc, port: 9001, targetPort: 9001, protocol: TCP, appProtocol: kubernetes.io/grpc }
EOF

${KC} -n "${AGW_NAMESPACE}" rollout restart deploy/ext-proc-guardrail 2>/dev/null || true
${KC} -n "${AGW_NAMESPACE}" rollout status deploy/ext-proc-guardrail --timeout=120s

###############################################################################
# 3. GatewayExtension + wire into oidc-extauth policy
###############################################################################
log "Creating GatewayExtension mcp-guardrails"
${KC} apply -n "${AGW_NAMESPACE}" -f - <<'EOF'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: GatewayExtension
metadata:
  name: mcp-guardrails
  namespace: agentgateway-system
spec:
  extProc:
    grpcService:
      backendRef:
        name: ext-proc-guardrail
        namespace: agentgateway-system
        port: 9001
    processingMode:
      requestHeaderMode: SEND
      requestBodyMode: BUFFERED
      responseHeaderMode: SEND
      responseBodyMode: NONE
EOF

log "Attaching GatewayExtension to oidc-extauth policy"
${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy oidc-extauth \
  --type='merge' \
  -p '{"spec":{"traffic":{"extProc":{"extensionRef":{"name":"mcp-guardrails"}}}}}'

log "ExtProc guardrail live"
cat <<EOF

What's now enforced on every MCP request body (before the upstream sees it):

  Schema:
    - tools/call name=echo    MUST have {message: string} only
    - tools/call name=get-sum MUST have {a: number, b: number} only
    Extra / missing / wrong-typed params → HTTP 400 + JSON-RPC -32602

  Content regex (any field, any tool):
    - SSN              \d{3}-\d{2}-\d{4}
    - Credit card      13-16 digits
    - Prompt injection "ignore previous instructions" / <|im_start|>
    - Exfiltration     "exfiltrate" / "exfil-data"

Test:
  ./examples/08-extproc-guardrails.sh

To remove: ./scripts/09b-extproc-guardrails.sh --cleanup
EOF
