#!/usr/bin/env bash
# test-lab-15-01.sh — Lab 15-01: Standalone
# Module 15: Taiga agile project management
# Basic taiga functionality in complete isolation
set -euo pipefail

LAB_ID="15-01"
LAB_NAME="Standalone"
MODULE="taiga"
COMPOSE_FILE="docker/docker-compose.standalone.yml"
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
echo ""

TAIGA_API="http://localhost:8001"
TAIGA_UI="http://localhost:8400"
NO_CLEANUP=${NO_CLEANUP:-0}

cleanup() {
    if [ "${NO_CLEANUP}" = "1" ]; then
        info "NO_CLEANUP=1 — skipping teardown"
    else
        info "Phase 4: Cleanup"
        docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
        info "Cleanup complete"
    fi
}
trap cleanup EXIT

section() { echo -e "\n${CYAN}## $1${NC}"; }

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 120s for Taiga to initialize (PostgreSQL + Redis + Django)..."
sleep 120

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

RUNNING=$(docker compose -f "${COMPOSE_FILE}" ps --format json 2>/dev/null | grep -c '"State":"running"' || \
    docker compose -f "${COMPOSE_FILE}" ps | grep -c 'Up' || echo 0)
if [ "${RUNNING}" -ge 4 ]; then
    pass "2.1 All 4 core containers running (db, redis, back, front)"
else
    fail "2.1 Expected 4 containers running, got ${RUNNING}"
fi

if docker compose -f "${COMPOSE_FILE}" ps taiga-s01-db 2>/dev/null | grep -q 'Up\|running'; then
    pass "2.2 PostgreSQL (taiga-s01-db) is up"
else
    fail "2.2 PostgreSQL is not running"
fi

if docker compose -f "${COMPOSE_FILE}" ps taiga-s01-back 2>/dev/null | grep -q 'Up\|running'; then
    pass "2.3 Taiga backend (taiga-s01-back) is up"
else
    fail "2.3 Taiga backend is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# 3.1 Backend API root
if curl -sf "${TAIGA_API}/api/v1/" 2>/dev/null | grep -q 'projects\|auth\|users\|404'; then
    pass "3.1 Taiga backend API root responds"
elif curl -o /dev/null -sw '%{http_code}' "${TAIGA_API}/api/v1/" 2>/dev/null | grep -q '200\|302\|404'; then
    pass "3.1 Taiga backend API root responds (HTTP 200/302/404)"
else
    fail "3.1 Taiga backend API not reachable at ${TAIGA_API}/api/v1/"
fi

# 3.2 Frontend UI loads
HTTP_CODE=$(curl -o /dev/null -sw '%{http_code}' "${TAIGA_UI}/" 2>/dev/null || echo 000)
if echo "${HTTP_CODE}" | grep -q '^[23]'; then
    pass "3.2 Taiga frontend UI accessible (HTTP ${HTTP_CODE})"
else
    fail "3.2 Taiga frontend UI not accessible (HTTP ${HTTP_CODE})"
fi

# 3.3 API auth endpoint
HTTP_AUTH=$(curl -o /dev/null -sw '%{http_code}' -X POST "${TAIGA_API}/api/v1/auth" \
    -H 'Content-Type: application/json' \
    -d '{"type":"normal","username":"invalid","password":"invalid"}' \
    2>/dev/null || echo 000)
if echo "${HTTP_AUTH}" | grep -q '^[24]'; then
    pass "3.3 Taiga auth endpoint reachable (HTTP ${HTTP_AUTH})"
else
    fail "3.3 Taiga auth endpoint not reachable (HTTP ${HTTP_AUTH})"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
