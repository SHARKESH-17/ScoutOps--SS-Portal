#!/usr/bin/env bash
# ScoutOps production deployment (Ubuntu / AWS EC2).
#
#   ./scripts/deploy.sh               validate -> build -> start DB -> start app -> verify
#   ./scripts/deploy.sh --no-build    reuse an existing scoutops:<version> image (used by Jenkins)
#
# Configuration comes from the environment or .env (DB_NAME, DB_USER, DB_PASSWORD,
# optional APP_PORT, SCOUTOPS_VERSION). Version defaults to the one in package.json.
# The script exits non-zero - and says so - if any step or health check fails.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

COMPOSE_FILE="docker-compose.prod.yml"
APP_SERVICE="scoutops-app"
DB_SERVICE="postgres"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
DO_BUILD=1

log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; exit 1; }
trap 'printf "[%s] DEPLOYMENT FAILED (line %s). The previous version is unchanged unless the app step already started.\n" "$(date +%T)" "$LINENO" >&2' ERR

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    -h|--help)  sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "Unknown argument: $arg (use --no-build or --help)" ;;
  esac
done

# Read a variable from the environment first, then from .env (never executed/sourced).
get_var() {
  local name="$1" value="${!1:-}"
  if [ -z "$value" ] && [ -f .env ]; then
    value="$(grep -E "^${name}=" .env | tail -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")" || true
  fi
  printf '%s' "$value"
}

compose() { SCOUTOPS_VERSION="$VERSION" docker compose -f "$COMPOSE_FILE" "$@"; }

container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo "missing"
}

wait_healthy() {  # wait_healthy <service> <seconds>
  local svc="$1" deadline=$(( SECONDS + $2 )) cid status
  while [ "$SECONDS" -lt "$deadline" ]; do
    cid="$(compose ps -q "$svc" || true)"
    if [ -n "$cid" ]; then
      status="$(container_health "$cid")"
      case "$status" in
        healthy) log "$svc is healthy"; return 0 ;;
        exited|dead) compose logs --tail=50 "$svc" >&2 || true; fail "$svc container stopped unexpectedly" ;;
      esac
    fi
    sleep 3
  done
  compose logs --tail=50 "$svc" >&2 || true
  fail "$svc did not become healthy within $2 seconds"
}

# 1 ---------------------------------------------------------------- validate
log "Step 1/6: validating environment"
for tool in docker curl; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed or not in PATH"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin not found (docker compose version)"
docker info >/dev/null 2>&1 || fail "Cannot talk to the Docker daemon (is it running? are you in the docker group?)"

DB_NAME_V="$(get_var DB_NAME)"; DB_USER_V="$(get_var DB_USER)"; DB_PASSWORD_V="$(get_var DB_PASSWORD)"
[ -n "$DB_NAME_V" ] || fail "DB_NAME is not set (environment or .env)"
[ -n "$DB_USER_V" ] || fail "DB_USER is not set (environment or .env)"
[ -n "$DB_PASSWORD_V" ] || fail "DB_PASSWORD is not set (environment or .env)"
[ "$DB_PASSWORD_V" != "change_me" ] || fail "DB_PASSWORD is still the placeholder 'change_me' - set a real password"

APP_PORT_V="$(get_var APP_PORT)"; APP_PORT_V="${APP_PORT_V:-3000}"
VERSION="$(get_var SCOUTOPS_VERSION)"
if [ -z "$VERSION" ]; then
  VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -n 1)"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version '$VERSION' is not MAJOR.MINOR.PATCH (needed for rollback)"
IMAGE="scoutops:$VERSION"

existing_cfg="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' scoutops-app 2>/dev/null || true)"
if [ -n "$existing_cfg" ] && [[ "$existing_cfg" != *docker-compose.prod.yml* ]]; then
  fail "A container named scoutops-app from the LOCAL stack exists. Run 'docker compose down' first."
fi

# Prepare PostgreSQL initialization files in a Snap-Docker-accessible path.
INIT_DIR="/home/ubuntu/scoutops-db-init"

mkdir -p "$INIT_DIR" ||
  fail "Cannot create PostgreSQL initialization directory: $INIT_DIR"

cp db/init.sql "$INIT_DIR/init.sql" ||
  fail "Cannot copy db/init.sql to $INIT_DIR"

chmod 644 "$INIT_DIR/init.sql" ||
  fail "Cannot set permissions on PostgreSQL initialization SQL"

compose config -q || fail "docker-compose.prod.yml failed validation"
log "Environment OK (version $VERSION, port $APP_PORT_V)"

# 2 ------------------------------------------------------------------- build
if [ "$DO_BUILD" -eq 1 ]; then
  log "Step 2/6: building image $IMAGE"
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "WARNING: $IMAGE already exists and will be overwritten - bump SCOUTOPS_VERSION to keep it for rollback"
  fi
  compose build "$APP_SERVICE"
else
  log "Step 2/6: --no-build given, using existing image $IMAGE"
  docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "Image $IMAGE does not exist"
fi
docker tag "$IMAGE" scoutops:latest

# 3 ----------------------------------------------------------------- database
log "Step 3/6: starting PostgreSQL"
compose up -d "$DB_SERVICE"
log "Step 4/6: waiting for PostgreSQL"
wait_healthy "$DB_SERVICE" "$HEALTH_TIMEOUT"

# 5 -------------------------------------------------------------- application
log "Step 5/6: starting ScoutOps ($IMAGE)"
compose up -d --no-build "$APP_SERVICE"
wait_healthy "$APP_SERVICE" "$HEALTH_TIMEOUT"

# 6 -------------------------------------------------------------------- verify
log "Step 6/6: verifying HTTP endpoints"
BASE="http://localhost:${APP_PORT_V}"
for path in /health /health/db; do
  ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if body="$(curl -fsS --max-time 5 "$BASE$path" 2>/dev/null)"; then ok=1; break; fi
    sleep 2
  done
  [ "$ok" -eq 1 ] || fail "GET $BASE$path did not return 2xx"
  log "GET $path -> $body"
done

trap - ERR
cat <<INFO

=====================================================
 ScoutOps deployed successfully
-----------------------------------------------------
 Version     : $VERSION   (image $IMAGE, also tagged :latest)
 Application : $BASE
 Health      : $BASE/health   |   $BASE/health/db
 Metrics     : $BASE/metrics
 Containers  : scoutops-app, scoutops-postgres
 Logs        : docker compose -f $COMPOSE_FILE logs -f
 Rollback    : ./scripts/rollback.sh
=====================================================
INFO
