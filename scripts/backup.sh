#!/usr/bin/env bash
# ScoutOps PostgreSQL backup (pg_dump, custom format, timestamped).
#
#   ./scripts/backup.sh
#
# Reads DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD from the environment or .env.
# BACKUP_DIR   where dumps go                         (default: ./backups)
# BACKUP_MODE  auto | host | docker                   (default: auto)
#                docker = run pg_dump INSIDE the postgres container (PostgreSQL is not
#                         published to the host, so this is the normal mode on a server)
#                host   = run pg_dump from this machine against DB_HOST:DB_PORT
#                auto   = docker if the container is running, otherwise host
# POSTGRES_CONTAINER   container name                 (default: scoutops-postgres)
# BACKUP_KEEP  if set, keep only the newest N dumps   (default: keep all)
#
# RESTORE (into a scratch database first - see README):
#   createdb -h HOST -U USER scoutops_restore_test
#   pg_restore -h HOST -U USER -d scoutops_restore_test --no-owner backups/<file>.dump
# or, with Docker:
#   docker exec scoutops-postgres createdb -U USER scoutops_restore_test
#   docker exec -i scoutops-postgres pg_restore -U USER -d scoutops_restore_test --no-owner < backups/<file>.dump
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; exit 1; }

get_var() {
  local name="$1" value="${!1:-}"
  if [ -z "$value" ] && [ -f .env ]; then
    value="$(grep -E "^${name}=" .env | tail -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")" || true
  fi
  printf '%s' "$value"
}

DB_HOST_V="$(get_var DB_HOST)"; DB_HOST_V="${DB_HOST_V:-localhost}"
DB_PORT_V="$(get_var DB_PORT)"; DB_PORT_V="${DB_PORT_V:-5432}"
DB_NAME_V="$(get_var DB_NAME)"
DB_USER_V="$(get_var DB_USER)"
DB_PASSWORD_V="$(get_var DB_PASSWORD)"
[ -n "$DB_NAME_V" ] || fail "DB_NAME is not set"
[ -n "$DB_USER_V" ] || fail "DB_USER is not set"
[ -n "$DB_PASSWORD_V" ] || fail "DB_PASSWORD is not set"

BACKUP_DIR="${BACKUP_DIR:-./backups}"
MODE="${BACKUP_MODE:-auto}"
CONTAINER="${POSTGRES_CONTAINER:-scoutops-postgres}"

container_running() {
  command -v docker >/dev/null 2>&1 && [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ]
}
if [ "$MODE" = "auto" ]; then
  if container_running; then MODE="docker"; else MODE="host"; fi
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="$BACKUP_DIR/scoutops_${DB_NAME_V}_${STAMP}.dump"
TMP="$FILE.partial"
trap 'rm -f "$TMP"' EXIT

case "$MODE" in
  docker)
    container_running || fail "Container $CONTAINER is not running"
    log "Backing up '$DB_NAME_V' via container $CONTAINER"
    PGPASSWORD="$DB_PASSWORD_V" docker exec -e PGPASSWORD "$CONTAINER" \
      pg_dump -U "$DB_USER_V" -d "$DB_NAME_V" --format=custom --no-owner > "$TMP"
    ;;
  host)
    command -v pg_dump >/dev/null 2>&1 || fail "pg_dump not found. Install postgresql-client or use BACKUP_MODE=docker"
    log "Backing up '$DB_NAME_V' from $DB_HOST_V:$DB_PORT_V"
    PGPASSWORD="$DB_PASSWORD_V" pg_dump -h "$DB_HOST_V" -p "$DB_PORT_V" -U "$DB_USER_V" -d "$DB_NAME_V" \
      --format=custom --no-owner > "$TMP" \
      || fail "pg_dump failed (DB_HOST='$DB_HOST_V' - note that 'postgres' only resolves inside Docker; use BACKUP_MODE=docker or DB_HOST=localhost)"
    ;;
  *) fail "Unknown BACKUP_MODE '$MODE' (auto|host|docker)" ;;
esac

[ -s "$TMP" ] || fail "Backup file is empty"

# Verify the archive is readable before declaring success.
if [ "$MODE" = "docker" ]; then
  docker exec -i "$CONTAINER" pg_restore --list < "$TMP" >/dev/null || fail "Backup verification failed (pg_restore --list)"
elif command -v pg_restore >/dev/null 2>&1; then
  pg_restore --list "$TMP" >/dev/null || fail "Backup verification failed (pg_restore --list)"
else
  log "WARNING: pg_restore not installed on host - archive not verified"
fi

mv "$TMP" "$FILE"
trap - EXIT
log "Backup created: $FILE ($(du -h "$FILE" | cut -f1))"

if [ -n "${BACKUP_KEEP:-}" ]; then
  if ! [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || [ "$BACKUP_KEEP" -lt 1 ]; then fail "BACKUP_KEEP must be a positive integer"; fi
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR"/scoutops_*.dump 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | while read -r old; do
    log "Removing old backup: $old"; rm -f -- "$old"
  done
fi
