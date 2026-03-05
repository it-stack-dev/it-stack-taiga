#!/usr/bin/env bash
# test-lab-15-06.sh — Lab 15-06: Production Deployment
# Module 15: Taiga agile project management
# taiga in production-grade HA configuration with monitoring
set -euo pipefail

LAB_ID="15-06"
LAB_NAME="Production Deployment"
MODULE="taiga"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0
CLEANUP=true

for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

# ── Colors ─────────────────────────────────────────────────────────────────────
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

# ── PHASE 1: Setup ─────────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 75s for ${MODULE} production stack to initialize..."
sleep 75

# ── PHASE 2: Health Checks ─────────────────────────────────────────────────────────
info "Phase 2: Container Health Checks"

for svc in taiga-p06-db taiga-p06-redis taiga-p06-ldap taiga-p06-kc taiga-p06-mail taiga-p06-back taiga-p06-front taiga-p06-events; do
  if docker inspect --format '{{.State.Status}}' "$svc" 2>/dev/null | grep -q running; then
    pass "$svc is running"
  else
    fail "$svc is NOT running"
  fi
done

# DB check
if docker exec taiga-p06-db pg_isready -U taiga -d taiga > /dev/null 2>&1; then
  pass "PostgreSQL is ready (pg_isready)"
else
  fail "PostgreSQL not ready"
fi

# Redis check
if docker exec taiga-p06-redis redis-cli ping 2>/dev/null | grep -q PONG; then
  pass "Redis responds to PING"
else
  fail "Redis PING failed"
fi

# KC check
if curl -sf http://localhost:8560/realms/master | grep -q realm; then
  pass "Keycloak accessible on port 8560"
else
  fail "Keycloak not accessible on port 8560"
fi

# Front accessible
if curl -sf http://localhost:8460/ | grep -q -i 'taiga\|html'; then
  pass "Taiga frontend accessible on port 8460"
else
  fail "Taiga frontend not accessible on port 8460"
fi

# ── PHASE 3: Production Checks ───────────────────────────────────────────────────
info "Phase 3a: Compose config validation"
if docker compose -f "${COMPOSE_FILE}" config -q 2>/dev/null; then
  pass "Production compose config is valid"
else
  fail "Production compose config validation failed"
fi

info "Phase 3b: Resource limits applied"
MEM=$(docker inspect --format '{{.HostConfig.Memory}}' taiga-p06-back 2>/dev/null || echo 0)
if [ "${MEM}" -gt 0 ] 2>/dev/null; then
  pass "Resource memory limit applied on taiga-p06-back (${MEM} bytes)"
else
  fail "No memory limit found on taiga-p06-back"
fi

info "Phase 3c: Restart policy check"
POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' taiga-p06-back 2>/dev/null || echo none)
if [ "${POLICY}" = "unless-stopped" ]; then
  pass "Restart policy is unless-stopped on taiga-p06-back"
else
  fail "Restart policy is '${POLICY}' (expected unless-stopped)"
fi

info "Phase 3d: Production environment variables"
IT_ENV=$(docker exec taiga-p06-back env 2>/dev/null | grep IT_STACK_ENV= | cut -d= -f2 || echo "")
if [ "${IT_ENV}" = "production" ]; then
  pass "IT_STACK_ENV=production set on taiga-p06-back"
else
  fail "IT_STACK_ENV not set to production (got: ${IT_ENV})"
fi

if docker exec taiga-p06-back env 2>/dev/null | grep -q CELERY_BROKER_URL; then
  pass "CELERY_BROKER_URL set on taiga-p06-back"
else
  fail "CELERY_BROKER_URL not set"
fi

info "Phase 3e: PostgreSQL database backup test"
if docker exec taiga-p06-db pg_dump -U taiga taiga > /dev/null 2>&1; then
  pass "pg_dump backup of taiga database succeeded"
else
  fail "pg_dump backup failed"
fi

info "Phase 3f: Redis session persistence test"
if docker exec taiga-p06-redis redis-cli SET test:session:prod06 "taiga-lab06" EX 300 2>/dev/null | grep -q OK; then
  VAL=$(docker exec taiga-p06-redis redis-cli GET test:session:prod06 2>/dev/null)
  if [ "${VAL}" = "taiga-lab06" ]; then
    pass "Redis session SET/GET test passed"
  else
    fail "Redis GET returned wrong value: ${VAL}"
  fi
else
  fail "Redis SET command failed"
fi

info "Phase 3g: Keycloak admin API token acquisition"
KC_TOKEN=$(curl -sf -X POST http://localhost:8560/realms/master/protocol/openid-connect/token \
  -d 'client_id=admin-cli&grant_type=password&username=admin&password=Admin06!' \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin API token acquired"
else
  fail "Failed to acquire Keycloak admin API token"
fi

info "Phase 3h: Events worker (Celery) container running"
if docker inspect --format '{{.State.Status}}' taiga-p06-events 2>/dev/null | grep -q running; then
  pass "Celery events worker container is running"
else
  fail "Celery events worker container is NOT running"
fi

info "Phase 3i: Redis restart resilience test"
docker restart taiga-p06-redis > /dev/null 2>&1
info "Waiting 15s for Redis to recover..."
sleep 15
if docker exec taiga-p06-redis redis-cli ping 2>/dev/null | grep -q PONG; then
  pass "Redis recovered after container restart"
else
  fail "Redis did NOT recover after container restart"
fi

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
if [ "${CLEANUP}" = true ]; then
  docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
  info "Cleanup complete"
else
  warn "Cleanup skipped (--no-cleanup flag set)"
fi

# ── Results ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi