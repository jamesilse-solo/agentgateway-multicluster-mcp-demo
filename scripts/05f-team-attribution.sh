#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05f-team-attribution.sh — Per-team cost attribution via JWT (Package 8)
#
# Addresses Nikhil's 5/18 ask: "cost tracking per project (project a/b/c
# under network team)". His framing was per-AWS-project = per-team
# (network-eng / project-a / project-b). The mechanism:
#
#   1. Each Keycloak user gets a `team` attribute on their profile.
#   2. Each Keycloak client has a UserAttribute protocol mapper that
#      copies `team` into the JWT as a top-level claim.
#   3. The JWT carrying `team` flows through ExtAuth as x-user-token.
#   4. The visible-identity console (Package 7) renders the team
#      prominently — operators / presenters can see attribution at a
#      glance.
#   5. AGW metrics CAN be configured to emit a `team` label by reading
#      the JWT claim (the EnterpriseAgentgatewayParameters metric block
#      already injects user_id; add a `team` field the same way). The
#      patch is small and is described in this script's summary so the
#      AGW operator can apply it.
#
# Prerequisites:
#   - 03b-keycloak.sh has run
#   - 04a-agw-management-ui.sh has run
#
# Usage:
#   ./scripts/05f-team-attribution.sh
###############################################################################

KUBE_CONTEXT="${KUBE_CONTEXT:-cluster1}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-solo-demo}"
AGW_NAMESPACE="${AGW_NAMESPACE:-agentgateway-system}"
KC="kubectl --context ${KUBE_CONTEXT}"

log() { echo ""; echo "=== $1 ==="; }

# Team assignments — edit to suit your customer's project structure.
# Format: <keycloak-username>=<team-name>
TEAMS=(
  "demo=network-eng"
  "tenant-a-agent=project-a"
  "tenant-b-agent=project-b"
)

###############################################################################
# 1. Acquire Keycloak admin token
###############################################################################
log "Acquiring Keycloak admin token"
KC_POD=$(${KC} -n "${KEYCLOAK_NAMESPACE}" get pod -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}')

# We exec kcadm.sh inside the keycloak pod — it already has KEYCLOAK_ADMIN
# credentials and a stable internal-cluster way to reach itself.
${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server "http://localhost:8080" \
    --realm master \
    --user "${KEYCLOAK_ADMIN_USER}" --password "${KEYCLOAK_ADMIN_PASSWORD}" \
    >/dev/null

###############################################################################
# 1b. Add `team` to the realm's user-profile schema
#
# Keycloak 24+ enforces declared user profile attributes by default — custom
# attributes set on a user are silently dropped unless they're declared in
# the realm's user-profile schema OR unmanagedAttributePolicy is ENABLED.
###############################################################################
log "Ensuring 'team' attribute is declared in the user-profile schema"
PROFILE=$(${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh get users/profile -r "${KEYCLOAK_REALM}" 2>/dev/null)
echo "${PROFILE}" | python3 -c "
import sys, json
p = json.load(sys.stdin)
attrs = p.setdefault('attributes', [])
if not any(a.get('name') == 'team' for a in attrs):
    attrs.append({
        'name': 'team',
        'displayName': 'Team',
        'multivalued': False,
        'permissions': {'view': ['admin', 'user'], 'edit': ['admin', 'user']}
    })
p['unmanagedAttributePolicy'] = 'ENABLED'
print(json.dumps(p))
" | ${KC} -n "${KEYCLOAK_NAMESPACE}" exec -i "${KC_POD}" -- /bin/sh -c \
  'cat > /tmp/profile.json && /opt/keycloak/bin/kcadm.sh update users/profile -r '"${KEYCLOAK_REALM}"' -f /tmp/profile.json' \
  2>&1 | tail -2 || true

###############################################################################
# 2. Set the team attribute on each user
###############################################################################
log "Setting team attribute on Keycloak users"
for ENTRY in "${TEAMS[@]}"; do
  USERNAME="${ENTRY%%=*}"
  TEAM="${ENTRY##*=}"
  echo "  ${USERNAME}  →  team=${TEAM}"
  USER_ID=$(${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
    /opt/keycloak/bin/kcadm.sh get users \
      -r "${KEYCLOAK_REALM}" \
      -q "username=${USERNAME}" --fields id --format csv --noquotes 2>/dev/null \
    | tail -1 | tr -d '\r')
  if [[ -z "${USER_ID}" ]]; then
    echo "    ⚠ user not found, skipping"
    continue
  fi
  ${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
    /opt/keycloak/bin/kcadm.sh update "users/${USER_ID}" \
      -r "${KEYCLOAK_REALM}" \
      -s "attributes.team=[\"${TEAM}\"]" >/dev/null
done

###############################################################################
# 3. Add a protocol mapper to each client to copy the team attribute into JWTs
###############################################################################
log "Adding UserAttribute protocol mapper to clients (claim: team)"
for CLIENT in agw-client tenant-a-client tenant-b-client mcp-service; do
  CID=$(${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
    /opt/keycloak/bin/kcadm.sh get clients \
      -r "${KEYCLOAK_REALM}" \
      -q "clientId=${CLIENT}" --fields id --format csv --noquotes 2>/dev/null \
    | tail -1 | tr -d '\r')
  if [[ -z "${CID}" ]]; then
    echo "  ${CLIENT}: not found, skipping"
    continue
  fi
  # Idempotent: check if mapper already exists
  EXISTS=$(${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
    /opt/keycloak/bin/kcadm.sh get "clients/${CID}/protocol-mappers/models" \
      -r "${KEYCLOAK_REALM}" --format csv --fields name --noquotes 2>/dev/null \
    | grep -c "^team-mapper$" || true)
  if [[ "${EXISTS}" == "0" ]]; then
    ${KC} -n "${KEYCLOAK_NAMESPACE}" exec "${KC_POD}" -- \
      /opt/keycloak/bin/kcadm.sh create "clients/${CID}/protocol-mappers/models" \
        -r "${KEYCLOAK_REALM}" \
        -s "name=team-mapper" \
        -s "protocol=openid-connect" \
        -s "protocolMapper=oidc-usermodel-attribute-mapper" \
        -s 'config."user.attribute"=team' \
        -s 'config."claim.name"=team' \
        -s 'config."jsonType.label"=String' \
        -s 'config."id.token.claim"=true' \
        -s 'config."access.token.claim"=true' \
        -s 'config."userinfo.token.claim"=true' >/dev/null
    echo "  ${CLIENT}: team-mapper created"
  else
    echo "  ${CLIENT}: team-mapper already present"
  fi
done

###############################################################################
# 4. Summary + optional AGW metric-label patch
###############################################################################
log "Team attribution wired through Keycloak"
cat <<EOF

JWTs issued by Keycloak now carry a 'team' claim. Verify:

  AGW_LB=\$(${KC} -n ${AGW_NAMESPACE} get gateway agentgateway-hub \\
    -o jsonpath='{.status.addresses[0].value}')
  TOKEN=\$(curl -s -X POST "http://\${AGW_LB}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \\
    -d 'grant_type=password' -d 'username=tenant-a-agent' -d 'password=tenant-a-pass' \\
    -d 'client_id=tenant-a-client' -d 'client_secret=tenant-a-client-secret' \\
    -d 'scope=openid email profile' | jq -r '.id_token')
  python3 -c "import sys,base64,json; s='\$TOKEN'.split('.')[1]; s+='='*(-len(s)%4); \\
    print(json.loads(base64.urlsafe_b64decode(s)).get('team'))"
  # → project-a

The visible-identity console (./scripts/04e-visible-identity.sh) renders
the team prominently on the user's session card.

OPTIONAL — add a 'team' metric label to AGW:
  Edit EnterpriseAgentgatewayParameters/agentgateway-config (created by
  04a-agw-management-ui.sh) and add to spec.rawConfig.config.metrics.fields.add:

      team: 'jwt.team'

  Then operators can query AGW metrics by team for cost attribution.
EOF
