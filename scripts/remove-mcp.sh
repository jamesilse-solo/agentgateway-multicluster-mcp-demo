#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# remove-mcp.sh — Reverse of add-mcp.sh. Deletes the Deployment first
#                  (which removes the AGW child HTTPRoute + backend), then
#                  the MCPServer.
#
# Usage:
#   ./remove-mcp.sh NAME [--tag T]
#   ./remove-mcp.sh --batch ./scripts/mcps.yaml
#
# Note: the parent HTTPRoute, Gateway label, and AR install itself are
# platform-level resources; they're managed by scripts/04-areg.sh
# (--cleanup removes them).
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
AR_NAMESPACE="${AR_NAMESPACE:-agentregistry-system}"
ARCTL_LOCAL_PORT="${ARCTL_LOCAL_PORT:-12121}"
export PATH="${HOME}/.arctl/bin:${PATH}"

KC="kubectl --context ${KUBE_CONTEXT}"
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
log()  { echo ""; echo -e "${B}=== $* ===${N}"; }
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
bad()  { echo -e "  ${R}✗${N} $*"; }

start_portforward() {
  command -v arctl >/dev/null || { bad "arctl not on PATH"; exit 1; }
  ${KC} -n "${AR_NAMESPACE}" port-forward svc/agentregistry-enterprise-server "${ARCTL_LOCAL_PORT}:12121" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill ${PF_PID} 2>/dev/null || true' EXIT INT TERM
  export ARCTL_API_BASE_URL="http://localhost:${ARCTL_LOCAL_PORT}"
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
}

remove_one() {
  local name="$1" tag="${2:-latest}"
  log "Removing ${name} (tag=${tag})"
  arctl delete deployment "${name}" 2>/dev/null && ok "Deployment/${name} deleted" \
    || warn "Deployment/${name} not present"
  arctl delete mcp "${name}" --tag "${tag}" 2>/dev/null && ok "MCPServer/${name} deleted" \
    || warn "MCPServer/${name} not present"
}

run_batch() {
  local file="$1"
  [[ -f "${file}" ]] || { bad "Batch file not found: ${file}"; exit 1; }
  command -v yq >/dev/null || { bad "yq is required for batch mode"; exit 1; }
  local count i=0
  count=$(yq '. | length' "${file}")
  while (( i < count )); do
    local name tag
    name=$(yq ".[${i}].name"        "${file}")
    tag=$(yq ".[${i}].tag // \"latest\"" "${file}")
    remove_one "${name}" "${tag}"
    i=$((i + 1))
  done
}

NAME=""; TAG="latest"; BATCH_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch) BATCH_FILE="$2"; shift 2 ;;
    --tag)   TAG="$2";        shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20; exit 0 ;;
    -*)      bad "Unknown flag: $1"; exit 2 ;;
    *)       NAME="$1"; shift ;;
  esac
done

start_portforward
if [[ -n "${BATCH_FILE}" ]]; then run_batch "${BATCH_FILE}"
elif [[ -n "${NAME}"   ]]; then remove_one "${NAME}" "${TAG}"
else bad "Usage: $0 NAME [--tag T]   or   $0 --batch FILE"; exit 2
fi
