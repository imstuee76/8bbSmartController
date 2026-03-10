#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
LOG_BASE="$DATA_DIR/logs/web-build"
DAY_LOCAL="$(date +%Y%m%d)"
SESSION_STAMP="$(date +%Y%m%dT%H%M%S%z)"
SESSION_ID="webbuild-${SESSION_STAMP}-$$"
ACTIVITY_LOG="$LOG_BASE/activity-$DAY_LOCAL.log"
ERROR_LOG="$LOG_BASE/errors-$DAY_LOCAL.log"
FLUTTER_HOME_DEFAULT="$APP_ROOT/.tools/flutter"
FLUTTER_BIN=""

mkdir -p "$LOG_BASE"

exec > >(tee -a "$ACTIVITY_LOG")
exec 2> >(tee -a "$ACTIVITY_LOG" "$ERROR_LOG" >&2)

log() {
  printf '[8bb-web-build] %s\n' "$*"
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
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      local line="$raw_line"
      line="${line//$'\r'/}"
      if [[ -z "${line//[[:space:]]/}" ]]; then
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
        continue
      fi
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      value="${value//$'\r'/}"
      if [[ "$value" =~ ^[[:space:]]*\"(.*)\"[[:space:]]*$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ ^[[:space:]]*\'(.*)\'[[:space:]]*$ ]]; then
        value="${BASH_REMATCH[1]}"
      else
        value="${value%%#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
      fi
      export "$key=$value"
    done <"$env_file"
  fi
}

resolve_flutter() {
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
    return 0
  fi
  local local_flutter="$FLUTTER_HOME_DEFAULT/bin/flutter"
  if [[ -x "$local_flutter" ]]; then
    FLUTTER_BIN="$local_flutter"
    export PATH="$(dirname "$FLUTTER_BIN"):$PATH"
    return 0
  fi
  return 1
}

ensure_flutter() {
  if resolve_flutter; then
    log "Using Flutter: $FLUTTER_BIN"
    return 0
  fi
  if [[ -x "$APP_ROOT/linux-controller-updater.sh" ]]; then
    log "Flutter missing. Running updater first."
    run "$APP_ROOT/linux-controller-updater.sh"
    if resolve_flutter; then
      log "Using Flutter after updater: $FLUTTER_BIN"
      return 0
    fi
  fi
  log "ERROR: Flutter is required but not found."
  exit 1
}

ensure_web_project() {
  local app_dir="$APP_ROOT/controller-app"
  if [[ -f "$app_dir/web/index.html" ]]; then
    return 0
  fi
  pushd "$app_dir" >/dev/null
  run "$FLUTTER_BIN" create --platforms=web,android .
  popd >/dev/null
}

build_web() {
  local app_dir="$APP_ROOT/controller-app"
  pushd "$app_dir" >/dev/null
  run "$FLUTTER_BIN" pub get
  run "$FLUTTER_BIN" build web --release --base-href /controller/
  popd >/dev/null
}

main() {
  log "Session: $SESSION_ID"
  log "App root: $APP_ROOT"
  log "Data dir: $DATA_DIR"
  export SMART_CONTROLLER_DATA_DIR="$DATA_DIR"
  export SMART_CONTROLLER_APP_ROOT="$APP_ROOT"
  load_env_file
  ensure_flutter
  ensure_web_project
  build_web
  log "Web build ready: $APP_ROOT/controller-app/build/web"
}

main "$@"
