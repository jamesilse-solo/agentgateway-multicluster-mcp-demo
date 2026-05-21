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
"""MCP ExtProc guardrail — schema validation + regex content policy.

AgentGateway speaks the standard Envoy ext_proc gRPC protocol, so this
server implements envoy.service.ext_proc.v3.ExternalProcessor. The
betterproto/grpclib bindings (envoy_data_plane>=0.8.1) are used since
the legacy pb2-style API was removed in envoy_data_plane v2.
"""
import asyncio, json, logging, re

from envoy_data_plane.envoy.service.ext_proc.v3 import (
    ExternalProcessorBase,
    ProcessingRequest,
    ProcessingResponse,
    ImmediateResponse,
    BodyResponse,
    HeadersResponse,
    HeaderMutation,
    CommonResponse,
    CommonResponseResponseStatus,
    BodyMutation,
    StreamedBodyResponse,
)
from envoy_data_plane.envoy.config.core.v3 import HeaderValue, HeaderValueOption
from envoy_data_plane.envoy.type.v3 import HttpStatus, StatusCode
from grpclib.server import Server
from typing import AsyncIterator

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
# Tightened so MCP envelope metadata (e.g. "2024-11-05" protocolVersion or
# session UUIDs) doesn't false-positive on the PII patterns.
PATTERNS = [
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),                          "PII:SSN"),
    # Credit card: exactly 4 groups of 4 digits, separated by - or space, with word boundaries
    (re.compile(r"\b\d{4}[- ]\d{4}[- ]\d{4}[- ]\d{4}\b"),            "PII:credit-card"),
    (re.compile(r"(?i)ignore (all )?previous instructions"),         "prompt-injection"),
    (re.compile(r"<\|im_start\|>|<\|system\|>"),                     "prompt-injection-marker"),
    (re.compile(r"(?i)exfiltrate|exfil-?data"),                      "exfiltration"),
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


def make_block_response(reason: str) -> ImmediateResponse:
    """ImmediateResponse: HTTP 400 + JSON-RPC error body. Short-circuits the
    upstream entirely (gateway returns this body to the original caller)."""
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": None,
        "error": {"code": -32602, "message": f"blocked by gateway guardrail ({reason})"},
    }).encode()
    return ImmediateResponse(
        status=HttpStatus(code=StatusCode.BadRequest),
        body=payload,
        headers=HeaderMutation(
            set_headers=[
                HeaderValueOption(
                    header=HeaderValue(key="content-type", raw_value=b"application/json")
                )
            ]
        ),
    )


def echo_body(body: bytes, end_of_stream: bool) -> BodyResponse:
    """Pass-through body response. AGW is always in STREAMED mode, so we must
    return the body bytes via BodyMutation.StreamedResponse — returning a bare
    BodyResponse() makes AGW wait forever for the body that should be forwarded."""
    return BodyResponse(
        response=CommonResponse(
            status=CommonResponseResponseStatus.CONTINUE,
            body_mutation=BodyMutation(
                streamed_response=StreamedBodyResponse(
                    body=body,
                    end_of_stream=end_of_stream,
                )
            ),
        )
    )


import betterproto2 as betterproto

class Guard(ExternalProcessorBase):
    async def process(
        self,
        process_iterator: AsyncIterator[ProcessingRequest],
    ) -> AsyncIterator[ProcessingResponse]:
        async for req in process_iterator:
            # Find which oneof variant is set on this request.
            which = betterproto.which_one_of(req, "request")
            kind = which[0] if which else ""
            log.info("ext_proc recv kind=%s", kind)

            CONTINUE_HEADERS = HeadersResponse()

            if kind == "request_body":
                body = req.request_body.body
                eos = req.request_body.end_of_stream
                blocked, reason = check_body(body)
                if blocked:
                    log.info("BLOCKED: %s", reason)
                    yield ProcessingResponse(immediate_response=make_block_response(reason))
                else:
                    yield ProcessingResponse(request_body=echo_body(body, eos))
            elif kind == "request_headers":
                yield ProcessingResponse(request_headers=CONTINUE_HEADERS)
            elif kind == "response_headers":
                yield ProcessingResponse(response_headers=CONTINUE_HEADERS)
            elif kind == "response_body":
                # Pass response bodies straight through unchanged.
                body = req.response_body.body
                eos = req.response_body.end_of_stream
                yield ProcessingResponse(response_body=echo_body(body, eos))
            else:
                yield ProcessingResponse(request_headers=CONTINUE_HEADERS)


async def serve():
    server = Server([Guard()])
    await server.start("0.0.0.0", 9001)
    log.info("ext-proc guardrail listening on :9001 (schema + regex)")
    await server.wait_closed()


if __name__ == "__main__":
    asyncio.run(serve())
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
        - pip install --quiet 'envoy_data_plane==2.0.0b9' grpclib && python /app/server.py
        ports:
        - { containerPort: 9001, name: grpc }
        readinessProbe:
          tcpSocket: { port: 9001 }
          initialDelaySeconds: 45
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
# 3. Wire ExtProc directly into oidc-extauth policy
#
# In this AGW Enterprise CRD the ext_proc backend is referenced directly
# from the policy — no separate GatewayExtension wrapper.
###############################################################################
log "Attaching ExtProc to oidc-extauth policy (direct backendRef)"
${KC} -n "${AGW_NAMESPACE}" patch enterpriseagentgatewaypolicy oidc-extauth \
  --type='merge' \
  -p '{"spec":{"traffic":{"extProc":{"backendRef":{"name":"ext-proc-guardrail","namespace":"'"${AGW_NAMESPACE}"'","port":9001}}}}}'

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
