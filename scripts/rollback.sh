#!/usr/bin/env bash
# ScoutOps rollback: switch the running application container to an older image tag.
#
#   ./scripts/rollback.sh              roll back to the previous version (next lower scoutops:X.Y.Z tag)
#   ./scripts/rollback.sh 1.0.3        roll back (or forward) to an explicit existing tag
#   ./scripts/rollback.sh --dry-run    show what would happen, change nothing
#
# Only the application image is rolled back. The database and its volume are untouched,
# so a rollback does not undo schema/data changes. Restore a backup for that (see backup.sh).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

COMPOSE_FILE="docker-compose.prod.yml"
APP_CONTAINER="scoutops-app"
APP_SERVICE="scoutops-app"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
DRY_RUN=0
TARGET=""

log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    [0-9]*.[0-9]*.[0-9]*) TARGET="$arg" ;;
    *) fail "Unknown argument: $arg" ;;
  esac
done

get_var() {
  local name="$1" value="${!1:-}"
  if [ -z "$value" ] && [ -f .env ]; then
    value="$(grep -E "^${name}=" .env | tail -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")" || true
  fi
  printf '%s' "$value"
}

for tool in docker curl; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed or not in PATH"
done
docker info >/dev/null 2>&1 || fail "Cannot talk to the Docker daemon"

# --- determine the current version from the RUNNING container -------------------------
current_image="$(docker inspect -f '{{.Config.Image}}' "$APP_CONTAINER" 2>/dev/null)" \
  || fail "Container $APP_CONTAINER not found. Deploy first with ./scripts/deploy.sh"
CURRENT="${current_image#*:}"
log "Current version: $CURRENT (image $current_image)"

# --- list available version tags (oldest -> newest) -----------------------------------
mapfile -t VERSIONS < <(docker images scoutops --format '{{.Tag}}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -u)
[ "${#VERSIONS[@]}" -gt 0 ] || fail "No versioned scoutops images (scoutops:X.Y.Z) found"
log "Available versions: ${VERSIONS[*]}"

# --- identify the target version -------------------------------------------------------
if [ -z "$TARGET" ]; then
  [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Current tag '$CURRENT' is not X.Y.Z - pass the target version explicitly"
  PREVIOUS=""
  for v in "${VERSIONS[@]}"; do
    if [ "$v" = "$CURRENT" ]; then break; fi
    PREVIOUS="$v"
  done
  [ -n "$PREVIOUS" ] || fail "No version older than $CURRENT is available - nothing to roll back to"
  TARGET="$PREVIOUS"
fi
docker image inspect "scoutops:$TARGET" >/dev/null 2>&1 || fail "Image scoutops:$TARGET does not exist"
[ "$TARGET" != "$CURRENT" ] || fail "Target version equals the running version ($CURRENT)"
log "Rollback target: $TARGET"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN: would replace $CURRENT with $TARGET. No changes made."
  exit 0
fi

# --- stop current app, start the previous version ------------------------------------
log "Stopping current application ($CURRENT)"
SCOUTOPS_VERSION="$TARGET" docker compose -f "$COMPOSE_FILE" stop "$APP_SERVICE"
log "Starting scoutops:$TARGET"
SCOUTOPS_VERSION="$TARGET" docker compose -f "$COMPOSE_FILE" up -d --no-build --no-deps --force-recreate "$APP_SERVICE"

# --- verify health ---------------------------------------------------------------------
deadline=$(( SECONDS + HEALTH_TIMEOUT )); status="unknown"
while [ "$SECONDS" -lt "$deadline" ]; do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$APP_CONTAINER" 2>/dev/null || echo missing)"
  [ "$status" = "healthy" ] && break
  sleep 3
done
if [ "$status" != "healthy" ]; then
  docker logs --tail=50 "$APP_CONTAINER" >&2 || true
  fail "ROLLBACK FAILED: scoutops:$TARGET started but is '$status'. The app is NOT healthy. Investigate with: docker logs $APP_CONTAINER"
fi

APP_PORT_V="$(get_var APP_PORT)"; APP_PORT_V="${APP_PORT_V:-3000}"
for path in /health /health/db; do
  ok=0
  for _ in 1 2 3 4 5; do
    if body="$(curl -fsS --max-time 5 "http://localhost:${APP_PORT_V}${path}" 2>/dev/null)"; then ok=1; break; fi
    sleep 2
  done
  [ "$ok" -eq 1 ] || fail "ROLLBACK FAILED: GET $path did not return 2xx after switching to $TARGET"
  log "GET $path -> $body"
done

log "ROLLBACK SUCCEEDED: $CURRENT -> $TARGET (container $APP_CONTAINER is healthy)"
