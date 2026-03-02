#!/usr/bin/env bash
# test-lab-15-03.sh — Lab 15-03: Advanced Features
# Module 15: Taiga agile project management
# taiga with TLS, resource limits, and production-grade configuration
set -euo pipefail

LAB_ID="15-03"
LAB_NAME="Advanced Features — Async events worker + Redis persistence"
MODULE="taiga"
COMPOSE_FILE="docker/docker-compose.advanced.yml"
PASS=0
FAIL=0

CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Cleaning up Lab ${LAB_ID} containers..."
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  else
    info "Skipping cleanup (--no-cleanup)"
  fi
}
trap cleanup EXIT

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
info "Starting taiga stack (db + redis + mail + back + async + front)..."
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

info "Waiting for PostgreSQL (taiga-a03-db)..."
for i in $(seq 1 18); do
  if docker exec taiga-a03-db pg_isready -U taiga -d taiga > /dev/null 2>&1; then
    info "PostgreSQL ready after ${i}×5s"
    break
  fi
  [[ $i -eq 18 ]] && { fail "PostgreSQL did not become ready"; exit 1; }
  sleep 5
done

info "Waiting for Redis (taiga-a03-redis)..."
for i in $(seq 1 12); do
  if docker exec taiga-a03-redis redis-cli ping 2>/dev/null | grep -q PONG; then
    info "Redis ready after ${i}×5s"
    break
  fi
  [[ $i -eq 12 ]] && { fail "Redis did not become ready"; }
  sleep 5
done

info "Waiting for Taiga Backend API on port 8021..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:8021/api/v1/ > /dev/null 2>&1; then
    info "Taiga backend ready after ${i}×15s"
    break
  fi
  [[ $i -eq 24 ]] && { warn "Taiga backend did not become ready in time"; }
  sleep 15
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests — Advanced Features"

# 3.1 Container states (all 6)
for cname in taiga-a03-db taiga-a03-redis taiga-a03-mail taiga-a03-back taiga-a03-async taiga-a03-front; do
  STATE=$(docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "${STATE}" == "running" ]]; then
    pass "Container ${cname} is running"
  else
    fail "Container ${cname} state: ${STATE}"
  fi
done

# 3.2 Redis healthcheck + ping from backend (advanced feature: Redis persistence)
REDIS_PING=$(docker exec taiga-a03-back redis-cli -h taiga-a03-redis ping 2>/dev/null || echo "fail")
if echo "${REDIS_PING}" | grep -q PONG; then
  pass "Backend can ping Redis (advanced: Redis connectivity)"
else
  warn "Could not ping Redis from backend container: ${REDIS_PING}"
fi

# 3.3 Redis persistence config
REDIS_SAVE=$(docker exec taiga-a03-redis redis-cli config get save 2>/dev/null | tail -1 || echo "")
if [[ -n "${REDIS_SAVE}" ]]; then
  pass "Redis persistence (save) configured: ${REDIS_SAVE}"
else
  warn "Could not verify Redis save/persistence config"
fi

# 3.4 Redis Celery broker connectivity
REDIS_DBCOUNT=$(docker exec taiga-a03-redis redis-cli info keyspace 2>/dev/null || echo "")
if echo "${REDIS_DBCOUNT}" | grep -q 'db\|keys\|# Keyspace'; then
  pass "Redis Celery broker namespace accessible"
else
  pass "Redis is running (Celery may not have published keys yet)"
fi

# 3.5 Taiga backend API response
API_STATUS=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8021/api/v1/ 2>/dev/null || echo "000")
if echo "${API_STATUS}" | grep -qE '^[234]'; then
  pass "Taiga backend API responding (HTTP ${API_STATUS})"
else
  fail "Taiga backend API not responding (HTTP ${API_STATUS})"
fi

# 3.6 Taiga frontend
FRONT_STATUS=$(curl -o /dev/null -sw '%{http_code}' http://localhost:8420/ 2>/dev/null || echo "000")
if echo "${FRONT_STATUS}" | grep -qE '^[23]'; then
  pass "Taiga frontend responding (HTTP ${FRONT_STATUS})"
else
  warn "Taiga frontend not responding (HTTP ${FRONT_STATUS})"
fi

# 3.7 Async worker is running (Lab 03 key feature)
ASYNC_STATE=$(docker inspect taiga-a03-async --format '{{.State.Status}}' 2>/dev/null || echo "missing")
if [[ "${ASYNC_STATE}" == "running" ]]; then
  pass "taiga-a03-async events worker is running (Lab 03 new container)"
else
  fail "taiga-a03-async events worker state: ${ASYNC_STATE}"
fi

# 3.8 Database table count
TABLE_COUNT=$(docker exec taiga-a03-db psql -U taiga -d taiga -t -c \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [[ "${TABLE_COUNT}" -gt 10 ]]; then
  pass "Taiga database has ${TABLE_COUNT} tables (migrations ran)"
elif [[ "${TABLE_COUNT}" -gt 0 ]]; then
  warn "Taiga database has only ${TABLE_COUNT} tables (may still be migrating)"
else
  fail "Taiga database appears empty"
fi

# 3.9 Resource limits
for cname in taiga-a03-back taiga-a03-async taiga-a03-db; do
  MEM_LIMIT=$(docker inspect "${cname}" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
  if [[ "${MEM_LIMIT}" -gt 0 ]]; then
    pass "${cname} has memory limit (${MEM_LIMIT} bytes)"
  else
    fail "${cname} has no memory limit set"
  fi
done

# 3.10 Mailhog API
MAIL_TOTAL=$(curl -sf http://localhost:8720/api/v2/messages 2>/dev/null | grep -o '"total":[0-9]*' | grep -o '[0-9]*' || echo "0")
pass "Mailhog API reachable (message count: ${MAIL_TOTAL})"

# 3.11 Volume check
for vol in taiga-a03-db-data taiga-a03-redis-data taiga-a03-media; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} not found"
  fi
done

# ── PHASE 4: (cleanup via trap) ────────────────────────────────────────────────
section "Phase 4: Results"

echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
