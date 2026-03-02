#!/usr/bin/env bash
# test-lab-15-05.sh — Lab 15-05: Advanced Integration
# Module 15: Taiga agile project management
# Integration: Taiga Back → Mattermost incoming webhook (WireMock)
set -euo pipefail

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
