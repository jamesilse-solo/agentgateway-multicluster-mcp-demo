#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# add-mcp.sh — Register a remote MCP server in AgentRegistry and expose it
#              through the existing AgentGateway at /registry/<path>.
#
# Run scripts/04-areg.sh once before using this.
#
# Two modes:
#
#   CLI:    ./add-mcp.sh NAME URL [--header H] [--path-suffix /SFX] [--tag T]
#   Batch:  ./add-mcp.sh --batch ./scripts/mcps.yaml
#
# CLI examples:
#   ./add-mcp.sh search-solo-io https://search.solo.io/mcp
#   ./add-mcp.sh github-copilot https://api.githubcopilot.com/mcp \
#     --header "Authorization: Bearer ${GITHUB_TOKEN}"
#   ./add-mcp.sh internal-tools http://tools.internal.svc.cluster.local:8080/mcp \
#     --path-suffix /tools
#
# Batch file format (YAML list):
#   - name: search-solo-io
#     url: https://search.solo.io/mcp
#     pathSuffix: /search-solo-io      # optional; default = /${name}
#     header: 'Authorization: Bearer ${TOKEN}'   # optional
#     tag: latest                       # optional; default = latest
#
# The Virtual Runtime adapter generates the underlying HTTPRoute +
# AgentgatewayBackend automatically. You never write Kubernetes YAML.
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AR_NAMESPACE="${AR_NAMESPACE:-agentregistry-system}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
AGW_GATEWAY_NAME="${AGW_GATEWAY_NAME:-agentgateway-hub}"
RUNTIME_NAME="${RUNTIME_NAME:-virtual-default}"
ARCTL_LOCAL_PORT="${ARCTL_LOCAL_PORT:-12121}"
READY_TIMEOUT="${READY_TIMEOUT:-60}"  # seconds

# Prefer the latest arctl that 04-areg.sh installs into ~/.arctl/bin
# (the v0.x in /usr/local/bin lacks `apply` and `get`).
export PATH="${HOME}/.arctl/bin:${PATH}"

KC="kubectl --context ${KUBE_CONTEXT}"
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
log()  { echo ""; echo -e "${B}=== $* ===${N}"; }
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
bad()  { echo -e "  ${R}✗${N} $*"; }

# ─── Port-forward to arctl (started here, killed on exit) ────────────────────
start_portforward() {
  command -v arctl >/dev/null || { bad "arctl not on PATH (run scripts/04-areg.sh first)"; exit 1; }
  ${KC} -n "${AR_NAMESPACE}" get svc agentregistry-enterprise-server >/dev/null 2>&1 \
    || { bad "AR not installed in ${AR_NAMESPACE} (run scripts/04-areg.sh first)"; exit 1; }
  ${KC} -n "${AR_NAMESPACE}" port-forward svc/agentregistry-enterprise-server "${ARCTL_LOCAL_PORT}:12121" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID} 2>/dev/null || true' EXIT INT TERM
  export ARCTL_API_BASE_URL="http://localhost:${ARCTL_LOCAL_PORT}"

  # Wait for the AR server to be reachable, then mint a demo-auth token.
  # (04-areg.sh installs AR with oidc.demoAuthEnabled=true; the embedded
  # autoauth IDP issues client_credentials tokens for client_id=admin.)
  for _ in $(seq 1 30); do
    curl -fs "${ARCTL_API_BASE_URL}/api/autoauth/.well-known/openid-configuration" >/dev/null 2>&1 && break
    sleep 0.5
  done
  ARCTL_API_TOKEN=$(curl -fs -X POST "${ARCTL_API_BASE_URL}/api/autoauth/oauth/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=client_credentials&client_id=admin&scope=openid profile email Groups' \
    | jq -r '.access_token // empty')
  [[ -n "${ARCTL_API_TOKEN}" ]] || { bad "Could not mint demo-auth token from AR"; exit 1; }
  export ARCTL_API_TOKEN

  arctl get runtime "${RUNTIME_NAME}" >/dev/null 2>&1 \
    || { bad "Runtime ${RUNTIME_NAME} not present in AR — re-run scripts/04-areg.sh"; exit 1; }
}

# ─── Translate non-Ready phases into human-friendly errors ───────────────────
explain_phase() {
  local phase="$1" err="$2"
  case "${err}" in
    *"no labeled Gateway"*)
      bad "No Gateway+HTTPRoute pair is labeled agentregistry.solo.io/runtime=${RUNTIME_NAME}"
      echo "      Run ./scripts/04-areg.sh to (re)apply the labels and parent HTTPRoute." ;;
    *"ResolvedRefs"*|*"RefNotPermitted"*)
      bad "Parent HTTPRoute can't resolve its cross-namespace backendRef"
      echo "      Check ReferenceGrant in ${AR_NAMESPACE}, and that AGW is on v2026.5.x+." ;;
    *"not remote"*|*"MCPServerNotRemote"*)
      bad "Target MCPServer has no spec.remote — Virtual runtime only supports remote MCPs." ;;
    *"pathSuffix"*)
      bad "spec.runtimeConfig.route.pathSuffix is missing or does not start with '/'" ;;
    "")
      bad "Deployment stuck in phase=${phase} (no error message — check AR server logs)" ;;
    *)
      bad "Deployment stuck (phase=${phase}): ${err}" ;;
  esac
}

# ─── Apply one MCP (used by both modes) ──────────────────────────────────────
register_one() {
  local name="$1" url="$2" path_suffix="$3" tag="$4" header="$5"

  # Validate name (DNS-1123 label rules — arctl will also enforce, but we
  # catch it early for a friendlier error).
  if [[ ! "${name}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    bad "name '${name}' must be lowercase DNS-1123 (a-z 0-9 -, ≤63 chars)"; return 1
  fi
  [[ "${path_suffix}" == /* ]] || { bad "pathSuffix '${path_suffix}' must start with /"; return 1; }

  log "Registering ${name}  →  ${url}  (path: /registry${path_suffix})"

  # Build YAML in a tempfile (so we never echo bearer tokens to the terminal).
  local tmp
  tmp=$(mktemp)
  trap "rm -f '${tmp}'" RETURN
  {
    cat <<EOF
apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: ${name}
spec:
  title: ${name}
  remote:
    type: streamable-http
    url: ${url}
EOF
    if [[ -n "${header}" ]]; then
      local hname="${header%%:*}" hval="${header#*:}"
      hval="${hval# }"  # trim leading space
      cat <<EOF
    headers:
    - name: ${hname}
      value: "${hval}"
EOF
    fi
    cat <<EOF
---
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: ${name}
spec:
  targetRef:
    kind: MCPServer
    name: ${name}
    tag: ${tag}
  runtimeRef:
    kind: Runtime
    name: ${RUNTIME_NAME}
  runtimeConfig:
    route:
      pathSuffix: ${path_suffix}
EOF
  } > "${tmp}"

  arctl apply -f "${tmp}" >/dev/null
  ok "MCPServer/${name} + Deployment/${name} applied"

  # Poll for phase=deployed. The yaml has top-level status.phase + status.error.
  local elapsed=0 phase="" err=""
  while (( elapsed < READY_TIMEOUT )); do
    local out
    out=$(arctl get deployment "${name}" -o yaml 2>/dev/null || echo "")
    if [[ -n "${out}" ]]; then
      phase=$(echo "${out}" | awk '/^  phase:/{print $2; exit}')
      err=$(echo "${out}"   | awk -F': ' '/^  error:/{$1=""; sub(/^ /,""); print; exit}')
      if [[ "${phase}" == "deployed" ]]; then
        # AR doesn't surface the LB URL in status; compute it from the gateway.
        local agw_lb
        agw_lb=$(${KC} -n "${AGW_NAMESPACE}" get gateway "${AGW_GATEWAY_NAME}" \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
        echo ""
        ok "Ready → http://${agw_lb}/registry${path_suffix}"
        echo "         (Bearer auth: same Keycloak JWT as /mcp)"
        return 0
      fi
    fi
    sleep 2; elapsed=$((elapsed + 2))
    printf "  ⏳ waiting for phase=deployed... (%ds, current=%s)\r" "${elapsed}" "${phase:-pending}"
  done
  echo ""
  explain_phase "${phase:-Timeout}" "${err}"
  return 1
}

# ─── Batch mode ──────────────────────────────────────────────────────────────
run_batch() {
  local file="$1"
  [[ -f "${file}" ]] || { bad "Batch file not found: ${file}"; exit 1; }
  command -v yq >/dev/null \
    || { bad "yq is required for batch mode (brew install yq, or pip install yq)"; exit 1; }

  local count
  count=$(yq '. | length' "${file}")
  log "Batch: ${count} MCP server(s) in ${file}"

  local i=0 failed=0
  while (( i < count )); do
    local name url path_suffix tag header
    name=$(yq ".[${i}].name"        "${file}")
    url=$(yq ".[${i}].url"          "${file}")
    path_suffix=$(yq ".[${i}].pathSuffix // \"/\" + .[${i}].name" "${file}")
    tag=$(yq ".[${i}].tag // \"latest\"" "${file}")
    header=$(yq ".[${i}].header // \"\"" "${file}")
    # envsubst-style interpolation of $VAR / ${VAR} inside the header value
    if [[ -n "${header}" && "${header}" == *'$'* ]]; then
      header=$(printf '%s' "${header}" | envsubst)
    fi
    register_one "${name}" "${url}" "${path_suffix}" "${tag}" "${header}" || failed=$((failed + 1))
    i=$((i + 1))
  done
  echo ""
  if (( failed == 0 )); then
    ok "Batch complete: ${count}/${count} ready"
  else
    bad "Batch finished with ${failed}/${count} failure(s)"
    exit 1
  fi
}

# ─── Arg parsing ─────────────────────────────────────────────────────────────
NAME=""; URL=""; HEADER=""; PATH_SUFFIX=""; TAG="latest"; BATCH_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch)        BATCH_FILE="$2"; shift 2 ;;
    --header)       HEADER="$2";     shift 2 ;;
    --path-suffix)  PATH_SUFFIX="$2"; shift 2 ;;
    --tag)          TAG="$2";        shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40
      exit 0 ;;
    -*)             bad "Unknown flag: $1"; exit 2 ;;
    *)
      if   [[ -z "${NAME}" ]]; then NAME="$1"
      elif [[ -z "${URL}"  ]]; then URL="$1"
      else bad "Unexpected positional arg: $1"; exit 2
      fi
      shift ;;
  esac
done

start_portforward

if [[ -n "${BATCH_FILE}" ]]; then
  run_batch "${BATCH_FILE}"
else
  [[ -n "${NAME}" && -n "${URL}" ]] \
    || { bad "Usage: $0 NAME URL [--header H] [--path-suffix /SFX] [--tag T]"; exit 2; }
  [[ -z "${PATH_SUFFIX}" ]] && PATH_SUFFIX="/${NAME}"
  register_one "${NAME}" "${URL}" "${PATH_SUFFIX}" "${TAG}" "${HEADER}"
fi
