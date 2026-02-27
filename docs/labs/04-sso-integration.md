# Lab 15-04 — SSO Integration

**Module:** 15 — Taiga agile project management  
**Duration:** See [lab manual](https://github.com/it-stack-dev/it-stack-docs)  
**Test Script:** 	ests/labs/test-lab-15-04.sh  
**Compose File:** docker/docker-compose.sso.yml

## Objective

Integrate taiga with Keycloak OIDC for single sign-on.

## Prerequisites

- Labs 15-01 through 15-03 pass
- Prerequisite services running

## Steps

### 1. Prepare Environment

```bash
cd it-stack-taiga
cp .env.example .env  # edit as needed
```

### 2. Start Services

```bash
make test-lab-04
```

Or manually:

```bash
docker compose -f docker/docker-compose.sso.yml up -d
```

### 3. Verify

```bash
docker compose ps
curl -sf http://localhost:80/health
```

### 4. Run Test Suite

```bash
bash tests/labs/test-lab-15-04.sh
```

## Expected Results

All tests pass with FAIL: 0.

## Cleanup

```bash
docker compose -f docker/docker-compose.sso.yml down -v
```

## Troubleshooting

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for common issues.
