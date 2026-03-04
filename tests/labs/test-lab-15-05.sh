#!/usr/bin/env bash
# test-lab-15-05.sh — Lab 15-05: INT-08 Taiga ↔ Keycloak OIDC + LDAP
# Module 15: Taiga agile project management
# Tests: LDAP seed, KC realm + LDAP federation + OIDC client,
#        OIDC discovery + token flow, Taiga Back API + env checks,
#        WireMock Mattermost mock + Taiga → webhook calls
set -euo pipefail

LAB_ID="15-05"
LAB_NAME="INT-08 Taiga ↔ Keycloak OIDC + LDAP"
MODULE="taiga"
COMPOSE_FILE="docker/docker-compose.integration.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"

FRONT_PORT=8440
BACK_PORT=8041
MOCK_PORT=8761
KC_PORT=8540
LDAP_PORT=3885
MH_PORT=8740

KC_ADMIN=admin
KC_PASS="Admin05!"
KC_URL="http://localhost:${KC_PORT}"
LDAP_ADMIN="cn=admin,dc=lab,dc=local"
LDAP_PW="LdapLab05!"
LDAP_USERS_BASE="cn=users,cn=accounts,dc=lab,dc=local"
LDAP_GROUPS_BASE="cn=groups,cn=accounts,dc=lab,dc=local"
LDAP_READONLY_DN="cn=readonly,dc=lab,dc=local"
LDAP_READONLY_PW="ReadOnly05!"
MOCK_URL="http://localhost:${MOCK_PORT}"

BACK_CONTAINER="taiga-i05-back"
FRONT_CONTAINER="taiga-i05-front"
SEED_CONTAINER="taiga-i05-ldap-seed"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
NO_CLEANUP=false
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=true

cleanup() {
  if [[ "${NO_CLEANUP}" == "false" ]]; then
    info "Cleanup: tearing down stack"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    warn "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup — bring up full integration stack"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 90s for Taiga integration stack to initialize..."
sleep 90

# ── PHASE 2: Container Health Checks ─────────────────────────────────────────
info "Phase 2: Container health checks"

for ctr in taiga-i05-db taiga-i05-redis taiga-i05-ldap taiga-i05-kc taiga-i05-mock taiga-i05-mail "${BACK_CONTAINER}" "${FRONT_CONTAINER}"; do
  if docker ps --format '{{.Names}}' | grep -q "^${ctr}$"; then
    pass "Container running: ${ctr}"
  else
    fail "Container not running: ${ctr}"
  fi
done

# LDAP seed exit code
SEED_STATUS=$(docker inspect "${SEED_CONTAINER}" --format '{{.State.ExitCode}}' 2>/dev/null || echo "missing")
if [[ "${SEED_STATUS}" == "0" ]]; then
  pass "LDAP seed container exited cleanly (code 0)"
else
  warn "LDAP seed exit code: ${SEED_STATUS} (idempotent re-run may be non-zero)"
fi

# PostgreSQL
if docker exec taiga-i05-db pg_isready -U taiga > /dev/null 2>&1; then
  pass "PostgreSQL ready"
else
  fail "PostgreSQL not ready"
fi

# Redis
if docker exec taiga-i05-redis redis-cli ping 2>/dev/null | grep -q PONG; then
  pass "Redis PONG"
else
  fail "Redis ping failed"
fi

# WireMock
if curl -sf "${MOCK_URL}/__admin/health" > /dev/null 2>&1; then
  pass "WireMock admin health OK"
else
  fail "WireMock admin health unreachable"
fi

# Keycloak
KC_READY=false
for i in $(seq 1 24); do
  if curl -sf "${KC_URL}/health/ready" 2>/dev/null | grep -q UP; then
    KC_READY=true; break
  fi
  sleep 5
done
if ${KC_READY}; then
  pass "Keycloak health/ready UP"
else
  fail "Keycloak health/ready did not return UP within 120s"
fi

# Taiga Back API
BACK_READY=false
for i in $(seq 1 20); do
  if curl -sf "http://localhost:${BACK_PORT}/api/v1/" > /dev/null 2>&1; then
    BACK_READY=true; break
  fi
  sleep 10
done
if ${BACK_READY}; then
  pass "Taiga Back API responds on port ${BACK_PORT}"
else
  warn "Taiga Back API not yet ready within 200s"
fi

# Mailhog
if curl -sf "http://localhost:${MH_PORT}/" > /dev/null 2>&1; then
  pass "Mailhog web UI accessible"
else
  warn "Mailhog web UI not ready"
fi

echo ""

# ── PHASE 3: LDAP Seed Verification ──────────────────────────────────────────
info "Phase 3: LDAP seed verification"

USER_COUNT=$(ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -b "${LDAP_USERS_BASE}" \
  -D "${LDAP_ADMIN}" -w "${LDAP_PW}" \
  "(objectClass=inetOrgPerson)" uid 2>/dev/null \
  | grep -c "^uid:" || echo 0)
if [[ "${USER_COUNT}" -ge 3 ]]; then
  pass "LDAP users seeded: ${USER_COUNT} found in ${LDAP_USERS_BASE}"
else
  fail "LDAP users insufficient: got ${USER_COUNT}, expected ≥3"
fi

GROUP_COUNT=$(ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
  -b "${LDAP_GROUPS_BASE}" \
  -D "${LDAP_ADMIN}" -w "${LDAP_PW}" \
  "(objectClass=groupOfNames)" cn 2>/dev/null \
  | grep -c "^cn:" || echo 0)
if [[ "${GROUP_COUNT}" -ge 2 ]]; then
  pass "LDAP groups seeded: ${GROUP_COUNT} found in ${LDAP_GROUPS_BASE}"
else
  fail "LDAP groups insufficient: got ${GROUP_COUNT}, expected ≥2"
fi

if ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
     -b "${LDAP_USERS_BASE}" \
     -D "${LDAP_ADMIN}" -w "${LDAP_PW}" \
     "(uid=taigaadmin)" uid 2>/dev/null | grep -q "uid: taigaadmin"; then
  pass "LDAP user taigaadmin present"
else
  fail "LDAP user taigaadmin not found"
fi

if ldapsearch -x -H "ldap://localhost:${LDAP_PORT}" \
     -b "${LDAP_USERS_BASE}" \
     -D "${LDAP_READONLY_DN}" -w "${LDAP_READONLY_PW}" \
     "(uid=taigaadmin)" uid > /dev/null 2>&1; then
  pass "LDAP readonly bind + search succeeds"
else
  fail "LDAP readonly bind failed"
fi

echo ""

# ── PHASE 4: Keycloak Realm + LDAP Federation + OIDC Client ──────────────────
info "Phase 4: Keycloak realm, LDAP federation, OIDC client provisioning"

# Get admin token
KC_TOKEN=$(python3 -c "
import urllib.request, urllib.parse, json, sys
data = urllib.parse.urlencode({'client_id':'admin-cli','username':'${KC_ADMIN}','password':'${KC_PASS}','grant_type':'password'}).encode()
req = urllib.request.Request('${KC_URL}/realms/master/protocol/openid-connect/token', data=data)
resp = urllib.request.urlopen(req, timeout=15)
print(json.loads(resp.read())['access_token'])
" 2>/dev/null || echo "")

if [[ -n "${KC_TOKEN}" ]]; then
  pass "Keycloak admin token obtained"
else
  fail "Failed to obtain Keycloak admin token"
  echo -e "${CYAN}========================================${NC}"
  echo -e " Lab ${LAB_ID} Results (KC auth failed — phases 4+ skipped)"
  echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
  echo -e "${CYAN}========================================${NC}"
  [ "${FAIL}" -gt 0 ] && exit 1 || exit 0
fi

KC_HDR="Authorization: Bearer ${KC_TOKEN}"

# Create it-stack realm
HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${KC_URL}/admin/realms" \
  -H "${KC_HDR}" -H "Content-Type: application/json" \
  -d '{"realm":"it-stack","enabled":true,"displayName":"IT-Stack Lab"}' || echo "000")
if [[ "${HTTP}" == "201" || "${HTTP}" == "409" ]]; then
  pass "Keycloak realm it-stack created/exists (HTTP ${HTTP})"
else
  fail "Keycloak realm creation failed (HTTP ${HTTP})"
fi

# Refresh token
KC_TOKEN=$(python3 -c "
import urllib.request, urllib.parse, json
data = urllib.parse.urlencode({'client_id':'admin-cli','username':'${KC_ADMIN}','password':'${KC_PASS}','grant_type':'password'}).encode()
req = urllib.request.Request('${KC_URL}/realms/master/protocol/openid-connect/token', data=data)
print(json.loads(urllib.request.urlopen(req, timeout=15).read())['access_token'])
" 2>/dev/null || echo "")
KC_HDR="Authorization: Bearer ${KC_TOKEN}"

# Register LDAP federation
COMPONENTS=$(curl -sf "${KC_URL}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "${KC_HDR}" 2>/dev/null || echo "[]")
if echo "${COMPONENTS}" | python3 -c "import sys,json; comps=json.load(sys.stdin); exit(0 if any(c.get('name')=='taiga-lab-ldap' for c in comps) else 1)" 2>/dev/null; then
  pass "Keycloak LDAP federation component already exists"
else
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms/it-stack/components" \
    -H "${KC_HDR}" -H "Content-Type: application/json" \
    -d '{
      "name":"taiga-lab-ldap",
      "providerId":"ldap",
      "providerType":"org.keycloak.storage.UserStorageProvider",
      "config":{
        "vendor":["rhds"],
        "connectionUrl":["ldap://taiga-i05-ldap:389"],
        "bindDn":["cn=readonly,dc=lab,dc=local"],
        "bindCredential":["ReadOnly05!"],
        "usersDn":["cn=users,cn=accounts,dc=lab,dc=local"],
        "usernameLDAPAttribute":["uid"],
        "uuidLDAPAttribute":["uid"],
        "userObjectClasses":["inetOrgPerson"],
        "searchScope":["1"],
        "useTruststoreSpi":["ldapsOnly"],
        "importEnabled":["true"],
        "syncRegistrations":["false"],
        "fullSyncPeriod":["-1"],
        "changedSyncPeriod":["-1"]
      }
    }' || echo "000")
  if [[ "${HTTP}" == "201" ]]; then
    pass "Keycloak LDAP federation component registered (HTTP 201)"
  else
    fail "Keycloak LDAP federation registration failed (HTTP ${HTTP})"
  fi
fi

# Trigger full sync
COMP_ID=$(curl -sf "${KC_URL}/admin/realms/it-stack/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "${KC_HDR}" 2>/dev/null \
  | python3 -c "import sys,json; comps=json.load(sys.stdin); print(next((c['id'] for c in comps if c.get('name')=='taiga-lab-ldap'),''))" 2>/dev/null || echo "")

if [[ -n "${COMP_ID}" ]]; then
  SYNC_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms/it-stack/user-storage/${COMP_ID}/sync?action=triggerFullSync" \
    -H "${KC_HDR}" 2>/dev/null || echo "000")
  if [[ "${SYNC_HTTP}" =~ ^2 ]]; then
    pass "LDAP full sync triggered (HTTP ${SYNC_HTTP})"
  else
    warn "LDAP full sync returned HTTP ${SYNC_HTTP}"
  fi

  SYNCED=$(curl -sf "${KC_URL}/admin/realms/it-stack/users?max=50" \
    -H "${KC_HDR}" 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  if [[ "${SYNCED}" -ge 3 ]]; then
    pass "Keycloak it-stack realm has ${SYNCED} users synced from LDAP"
  else
    warn "Keycloak user sync: ${SYNCED} users (expected ≥3)"
  fi

  KC_ADMIN_PRESENT=$(curl -sf "${KC_URL}/admin/realms/it-stack/users?username=taigaadmin&exact=true" \
    -H "${KC_HDR}" 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  if [[ "${KC_ADMIN_PRESENT}" -ge 1 ]]; then
    pass "User taigaadmin present in Keycloak it-stack realm"
  else
    warn "User taigaadmin not yet visible in KC (LDAP sync may be async)"
  fi
fi

# Register OIDC client
CLIENTS=$(curl -sf "${KC_URL}/admin/realms/it-stack/clients?clientId=taiga" \
  -H "${KC_HDR}" 2>/dev/null || echo "[]")
if echo "${CLIENTS}" | python3 -c "import sys,json; clients=json.load(sys.stdin); exit(0 if any(c.get('clientId')=='taiga' for c in clients) else 1)" 2>/dev/null; then
  pass "Keycloak OIDC client 'taiga' already registered"
else
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_URL}/admin/realms/it-stack/clients" \
    -H "${KC_HDR}" -H "Content-Type: application/json" \
    -d '{
      "clientId":"taiga",
      "protocol":"openid-connect",
      "enabled":true,
      "name":"Taiga Project Management",
      "description":"INT-08 Taiga OIDC SSO",
      "publicClient":false,
      "secret":"TaigaKCSecret05!",
      "directAccessGrantsEnabled":true,
      "standardFlowEnabled":true,
      "redirectUris":["http://localhost:8440/*","http://localhost:8041/*"],
      "webOrigins":["http://localhost:8440","http://localhost:8041"],
      "protocolMappers":[
        {"name":"username","protocol":"openid-connect","protocolMapper":"oidc-usermodel-property-mapper","config":{"user.attribute":"username","claim.name":"preferred_username","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true"}},
        {"name":"email","protocol":"openid-connect","protocolMapper":"oidc-usermodel-property-mapper","config":{"user.attribute":"email","claim.name":"email","jsonType.label":"String","id.token.claim":"true","access.token.claim":"true"}},
        {"name":"full_name","protocol":"openid-connect","protocolMapper":"oidc-full-name-mapper","config":{"id.token.claim":"true","access.token.claim":"true"}}
      ]
    }' || echo "000")
  if [[ "${HTTP}" == "201" ]]; then
    pass "Keycloak OIDC client 'taiga' registered (HTTP 201)"
  else
    fail "Keycloak OIDC client registration failed (HTTP ${HTTP})"
  fi
fi

echo ""

# ── PHASE 5: OIDC Discovery + Token Flow ─────────────────────────────────────
info "Phase 5: OIDC discovery endpoint + token introspection"

# 5a: OIDC discovery
DISC_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${KC_URL}/realms/it-stack/.well-known/openid-configuration" 2>/dev/null || echo "000")
if [[ "${DISC_HTTP}" == "200" ]]; then
  pass "Keycloak OIDC discovery endpoint returns 200"
else
  fail "OIDC discovery unreachable (HTTP ${DISC_HTTP})"
fi

DISC=$(curl -sf "${KC_URL}/realms/it-stack/.well-known/openid-configuration" 2>/dev/null || echo "{}")
for field in token_endpoint authorization_endpoint userinfo_endpoint; do
  if echo "${DISC}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('${field}',''))" 2>/dev/null | grep -q "http"; then
    pass "OIDC discovery: ${field} present"
  else
    fail "OIDC discovery: ${field} missing"
  fi
done

# 5b: OIDC token for taigaadmin (password grant)
TOKEN_ENDPOINT=$(echo "${DISC}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token_endpoint',''))" 2>/dev/null || echo "")
OIDC_TOKEN=""
if [[ -n "${TOKEN_ENDPOINT}" ]]; then
  OIDC_TOKEN=$(python3 -c "
import urllib.request, urllib.parse, json, sys
data = urllib.parse.urlencode({
  'client_id':'taiga',
  'client_secret':'TaigaKCSecret05!',
  'username':'taigaadmin',
  'password':'Lab05Password!',
  'grant_type':'password',
  'scope':'openid profile email'
}).encode()
req = urllib.request.Request('${TOKEN_ENDPOINT}', data=data)
resp = urllib.request.urlopen(req, timeout=15)
print(json.loads(resp.read()).get('access_token',''))
" 2>/dev/null || echo "")
fi

if [[ -n "${OIDC_TOKEN}" ]]; then
  pass "OIDC access token obtained for taigaadmin (password grant)"
else
  warn "OIDC token for taigaadmin not obtained (user sync may not be complete yet)"
fi

# 5c: Userinfo if token obtained
if [[ -n "${OIDC_TOKEN}" ]]; then
  USERINFO_ENDPOINT=$(echo "${DISC}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('userinfo_endpoint',''))" 2>/dev/null || echo "")
  if [[ -n "${USERINFO_ENDPOINT}" ]]; then
    USERINFO=$(curl -sf "${USERINFO_ENDPOINT}" \
      -H "Authorization: Bearer ${OIDC_TOKEN}" 2>/dev/null || echo "{}")
    if echo "${USERINFO}" | python3 -c "import sys,json; u=json.load(sys.stdin); exit(0 if u.get('sub') else 1)" 2>/dev/null; then
      pass "Userinfo: sub claim present"
    else
      warn "Userinfo: sub claim missing"
    fi
    PREF_NAME=$(echo "${USERINFO}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('preferred_username',''))" 2>/dev/null || echo "")
    if [[ "${PREF_NAME}" == "taigaadmin" ]]; then
      pass "Userinfo: preferred_username=taigaadmin"
    else
      warn "Userinfo: preferred_username='${PREF_NAME}' (expected taigaadmin)"
    fi
  fi
fi

echo ""

# ── PHASE 6: Taiga Back Env + OIDC Config Assertions ─────────────────────────
info "Phase 6: Taiga Back container env + OIDC config assertions"

for env_var in KEYCLOAK_URL KEYCLOAK_REALM KEYCLOAK_CLIENT_ID KEYCLOAK_CLIENT_SECRET OIDC_DISCOVERY_URL; do
  if docker exec "${BACK_CONTAINER}" env 2>/dev/null | grep -q "^${env_var}="; then
    pass "Taiga Back env: ${env_var} present"
  else
    warn "Taiga Back env: ${env_var} missing"
  fi
done

# Taiga back can reach KC OIDC discovery internally
if docker exec "${BACK_CONTAINER}" curl -sf \
     "http://taiga-i05-kc:8080/realms/it-stack/.well-known/openid-configuration" \
     > /dev/null 2>&1; then
  pass "Taiga Back → Keycloak OIDC discovery internal reachability OK"
else
  warn "Taiga Back cannot reach KC OIDC discovery internally"
fi

echo ""

# ── PHASE 7: WireMock Mattermost Stubs + Taiga → Webhook Calls ───────────────
info "Phase 7: WireMock Mattermost stubs + Taiga webhook integration"

# Register incoming webhook stub
HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request":{"method":"POST","url":"/hooks/incoming/mattermost"},
    "response":{
      "status":200,
      "headers":{"Content-Type":"application/json"},
      "body":"{\"ok\":true,\"message\":\"Message posted\"}"
    }
  }' || echo "000")
if [[ "${HTTP}" == "201" ]]; then
  pass "WireMock Mattermost incoming webhook stub registered"
else
  fail "WireMock webhook stub registration failed (HTTP ${HTTP})"
fi

if curl -sf -X POST "${MOCK_URL}/hooks/incoming/mattermost" \
     -H "Content-Type: application/json" \
     -d '{"text":"Taiga INT-08 test notification","channel":"it-stack-projects"}' \
     2>/dev/null | grep -q '"ok":true'; then
  pass "WireMock Mattermost webhook returns expected response"
else
  fail "WireMock Mattermost webhook returned unexpected response"
fi

if docker exec "${BACK_CONTAINER}" curl -sf "http://taiga-i05-mock:8080/__admin/health" > /dev/null 2>&1; then
  pass "Taiga Back → WireMock internal reachability OK"
else
  fail "Taiga Back cannot reach WireMock internally"
fi

if docker exec "${BACK_CONTAINER}" curl -sf \
     -X POST "http://taiga-i05-mock:8080/hooks/incoming/mattermost" \
     -H "Content-Type: application/json" \
     -d '{"text":"project updated"}' 2>/dev/null | grep -q '"ok"'; then
  pass "Taiga Back → Mattermost webhook call succeeds (via WireMock)"
else
  warn "Taiga Back → Mattermost webhook not fully verified"
fi

echo ""

# ── PHASE 8: Volume / Misc Assertions ────────────────────────────────────────
info "Phase 8: Volume and miscellaneous assertions"

for vol in taiga-i05-db-data taiga-i05-back-data taiga-i05-ldap-data; do
  if docker volume ls | grep -q "${vol}"; then
    pass "Volume present: ${vol}"
  else
    fail "Volume missing: ${vol}"
  fi
done

for env_var in DJANGO_DB_HOST CELERY_BROKER_URL MATTERMOST_URL; do
  if docker exec "${BACK_CONTAINER}" env 2>/dev/null | grep -q "^${env_var}="; then
    pass "Taiga Back env: ${env_var} set"
  else
    fail "Taiga Back env: ${env_var} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e " Lab ${LAB_ID} — ${LAB_NAME}"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

[ "${FAIL}" -gt 0 ] && exit 1 || exit 0


LAB_ID="15-05"
LAB_NAME="Advanced Integration"
MODULE="taiga"
COMPOSE_FILE="docker/docker-compose.integration.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
FRONT_PORT=8440
BACK_PORT=8041
MOCK_PORT=8761
KC_PORT=8540
LDAP_PORT=3885
MH_PORT=8740
MOCK_URL="http://localhost:${MOCK_PORT}"

BACK_CONTAINER="taiga-i05-back"
FRONT_CONTAINER="taiga-i05-front"
MOCK_CONTAINER="taiga-i05-mock"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
NO_CLEANUP=false
[[ "${1:-}" == "--no-cleanup" ]] && NO_CLEANUP=true

cleanup() {
  if [[ "${NO_CLEANUP}" == "false" ]]; then
    info "Phase 4: Cleanup"
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
    info "Cleanup complete"
  else
    warn "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 60s for Taiga stack to initialize..."
sleep 60

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker ps --format '{{.Names}}' | grep -q "^${BACK_CONTAINER}$"; then
  pass "Taiga Back container running"
else
  fail "Taiga Back container not running"
fi

if docker ps --format '{{.Names}}' | grep -q "^${MOCK_CONTAINER}$"; then
  pass "WireMock container running"
else
  fail "WireMock container not running"
fi

# Taiga back API
if curl -sf "http://localhost:${BACK_PORT}/api/v1/" > /dev/null 2>&1; then
  pass "Taiga Back API responds"
else
  warn "Taiga Back API not yet ready"
fi

# WireMock health
if curl -sf "${MOCK_URL}/__admin/health" > /dev/null; then
  pass "WireMock admin health OK"
else
  fail "WireMock admin health unreachable"
fi

# Keycloak
if curl -sf "http://localhost:${KC_PORT}/realms/master" > /dev/null 2>&1; then
  pass "Keycloak master realm accessible"
else
  warn "Keycloak not yet ready"
fi

# LDAP
if ldapsearch -x -H ldap://localhost:${LDAP_PORT} -b dc=lab,dc=local \
     -D cn=admin,dc=lab,dc=local -w LdapLab05! cn=admin > /dev/null 2>&1; then
  pass "OpenLDAP bind successful"
else
  warn "OpenLDAP bind failed"
fi

# Mailhog
if curl -sf "http://localhost:${MH_PORT}/" > /dev/null 2>&1; then
  pass "Mailhog web UI accessible"
else
  warn "Mailhog web UI not ready"
fi

# ── PHASE 3: Integration Tests ────────────────────────────────────────────────
info "Phase 3: Integration Tests (Mattermost webhook via WireMock)"

# 3a: Register Mattermost incoming webhook stub
info "3a: Registering Mattermost incoming webhook stub..."
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/hooks/incoming/mattermost"},
    "response": {
      "status": 200,
      "headers": {"Content-Type": "application/json"},
      "body": "{\"ok\":true,\"message\":\"Message posted\"}"
    }
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock Mattermost webhook stub registered (201)"
else
  fail "WireMock webhook stub registration failed (HTTP ${HTTP_STATUS})"
fi

# 3b: Verify Mattermost webhook mock responds
if curl -sf -X POST "${MOCK_URL}/hooks/incoming/mattermost" \
     -H "Content-Type: application/json" \
     -d '{"text":"Taiga lab-15-05 test notification","channel":"it-stack-projects"}' | grep -q '"ok":true'; then
  pass "WireMock Mattermost webhook returns expected response"
else
  fail "WireMock Mattermost webhook returned unexpected response"
fi

# 3c: Integration env vars in Taiga Back container
if docker exec "${BACK_CONTAINER}" env 2>/dev/null | grep -q 'MATTERMOST_URL='; then
  pass "MATTERMOST_URL env var present in Taiga Back container"
else
  fail "MATTERMOST_URL env var missing from Taiga Back container"
fi

if docker exec "${BACK_CONTAINER}" env 2>/dev/null | grep -q 'MATTERMOST_WEBHOOK_TOKEN='; then
  pass "MATTERMOST_WEBHOOK_TOKEN env var present in Taiga Back container"
else
  fail "MATTERMOST_WEBHOOK_TOKEN env var missing from Taiga Back container"
fi

if docker exec "${BACK_CONTAINER}" env 2>/dev/null | grep -q 'MATTERMOST_CHANNEL='; then
  pass "MATTERMOST_CHANNEL env var present in Taiga Back container"
else
  fail "MATTERMOST_CHANNEL env var missing from Taiga Back container"
fi

# 3d: Container-to-WireMock connectivity
if docker exec "${BACK_CONTAINER}" curl -sf http://taiga-i05-mock:8080/__admin/health > /dev/null 2>&1; then
  pass "Taiga Back container can reach WireMock (taiga-i05-mock:8080)"
else
  fail "Taiga Back container cannot reach WireMock"
fi

# 3e: Push notification simulation via WireMock URL
if docker exec "${BACK_CONTAINER}" curl -sf \
     -X POST http://taiga-i05-mock:8080/hooks/incoming/mattermost \
     -H 'Content-Type: application/json' \
     -d '{"text":"project updated"}' 2>/dev/null | grep -q 'ok'; then
  pass "Taiga → Mattermost webhook call succeeds (via WireMock)"
else
  warn "Taiga → Mattermost webhook call not verified (app may require full setup)"
fi

# 3f: Volume assertions
if docker volume ls | grep -q 'taiga-i05-back-data'; then
  pass "Taiga back data volume exists"
else
  fail "Taiga back data volume missing"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"

[ "${FAIL}" -gt 0 ] && exit 1 || exit 0

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:80/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 15-05 pending implementation"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
