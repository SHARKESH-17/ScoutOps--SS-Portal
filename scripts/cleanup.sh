#!/usr/bin/env bash
# ScoutOps Docker cleanup. SAFE by default.
#
#   ./scripts/cleanup.sh                 asks for confirmation, then removes:
#                                          stopped containers, unused networks,
#                                          dangling images, build cache, ./.tmp, ./coverage
#   ./scripts/cleanup.sh --dry-run       print what would run, change nothing
#   ./scripts/cleanup.sh --yes           skip the confirmation prompt (CI)
#   ./scripts/cleanup.sh --keep-versions N
#                                        additionally remove scoutops:X.Y.Z images except the
#                                        newest N and the one in use (keeps rollback targets)
#
# Docker VOLUMES are never touched - the PostgreSQL data volumes
# (scoutops_pgdata, scoutops_prod_pgdata) are not removed by this script.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

DRY_RUN=0; ASSUME_YES=0; KEEP=""
log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%T)" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --keep-versions)
      shift; KEEP="${1:-}"
      if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then fail "--keep-versions needs a positive integer"; fi
      ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "Cannot talk to the Docker daemon"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then log "DRY RUN: $*"; else log "Running: $*"; "$@"; fi
}

cat <<PLAN
This will remove:
  - all stopped containers   (docker container prune)
  - unused networks          (docker network prune)
  - dangling images          (docker image prune)
  - Docker build cache       (docker builder prune)
  - ./.tmp and ./coverage
${KEEP:+  - old scoutops:X.Y.Z images, keeping the newest $KEEP and the one in use
}It will NOT remove Docker volumes (database data is safe).
PLAN

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "Proceed? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

run docker container prune -f
run docker network prune -f
run docker image prune -f
run docker builder prune -f
run rm -rf ./.tmp ./coverage

if [ -n "$KEEP" ]; then
  in_use="$(docker ps -a --format '{{.Image}}' | sed -n 's/^scoutops://p' | sort -u)"
  mapfile -t ALL < <(docker images scoutops --format '{{.Tag}}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -u)
  total="${#ALL[@]}"
  for i in "${!ALL[@]}"; do
    v="${ALL[$i]}"
    if [ "$i" -ge $(( total - KEEP )) ]; then continue; fi
    if printf '%s\n' "$in_use" | grep -qx "$v"; then log "Keeping scoutops:$v (in use)"; continue; fi
    run docker rmi "scoutops:$v"
  done
fi

log "Cleanup finished. Database volumes were not touched."
