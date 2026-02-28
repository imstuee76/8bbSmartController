#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
LOG_BASE="$DATA_DIR/logs/controller/sessions"
DAY_UTC="$(date -u +%Y%m%d)"
SESSION_ID="controller-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SESSION_DIR="$LOG_BASE/$SESSION_ID"
ACTIVITY_LOG="$SESSION_DIR/activity-$DAY_UTC.log"
ERROR_LOG="$SESSION_DIR/errors-$DAY_UTC.log"

mkdir -p "$SESSION_DIR"
mkdir -p "$DATA_DIR/logs/updater"

exec > >(tee -a "$ACTIVITY_LOG")
exec 2> >(tee -a "$ERROR_LOG" >&2)

log() {
  printf '[8bb-controller] %s\n' "$*"
}

run() {
  log "\$ $*"
  "$@"
}

load_env_file() {
  local env_file=""
  if [[ -f "$DATA_DIR/.env" ]]; then
    env_file="$DATA_DIR/.env"
  elif [[ -f "$APP_ROOT/.env" ]]; then
    env_file="$APP_ROOT/.env"
  fi
  if [[ -n "$env_file" ]]; then
    log "Loading env from $env_file"
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

main() {
  log "Session: $SESSION_ID"
  log "App root: $APP_ROOT"
  log "Data dir: $DATA_DIR"
  export SMART_CONTROLLER_DATA_DIR="$DATA_DIR"
  load_env_file

  if ! command -v flutter >/dev/null 2>&1; then
    log "ERROR: Flutter is required but not found in PATH."
    exit 1
  fi

  pushd "$APP_ROOT/controller-app" >/dev/null
  run flutter pub get
  run flutter run -d linux --target lib/main.dart "$@"
  popd >/dev/null
}

main "$@"
