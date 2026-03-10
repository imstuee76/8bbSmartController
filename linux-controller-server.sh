#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
LOG_BASE="$DATA_DIR/logs/server"
DAY_LOCAL="$(date +%Y%m%d)"
SESSION_STAMP="$(date +%Y%m%dT%H%M%S%z)"
SESSION_ID="server-${SESSION_STAMP}-$$"
ACTIVITY_LOG="$LOG_BASE/activity-$DAY_LOCAL.log"
ERROR_LOG="$LOG_BASE/errors-$DAY_LOCAL.log"

mkdir -p "$LOG_BASE"

exec > >(tee -a "$ACTIVITY_LOG")
exec 2> >(tee -a "$ACTIVITY_LOG" "$ERROR_LOG" >&2)

log() {
  printf '[8bb-server] %s\n' "$*"
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

main() {
  local host="${CONTROLLER_SERVER_HOST:-0.0.0.0}"
  local port="${CONTROLLER_SERVER_PORT:-1111}"
  local backend_dir="$APP_ROOT/flasher-web"
  local web_dir="${CONTROLLER_WEB_DIR:-$APP_ROOT/controller-app/build/web}"

  log "Session: $SESSION_ID"
  log "App root: $APP_ROOT"
  log "Data dir: $DATA_DIR"
  export SMART_CONTROLLER_DATA_DIR="$DATA_DIR"
  export SMART_CONTROLLER_APP_ROOT="$APP_ROOT"
  load_env_file

  if [[ ! -f "$backend_dir/requirements.txt" ]]; then
    log "ERROR: Missing backend requirements file: $backend_dir/requirements.txt"
    exit 1
  fi

  if [[ ! -d "$web_dir" ]]; then
    log "WARNING: Controller web build missing: $web_dir"
    log "Run ./linux-controller-build-web.sh to generate /controller/ app."
  fi

  export CONTROLLER_WEB_DIR="$web_dir"
  pushd "$backend_dir" >/dev/null
  run python3 -m uvicorn app.main:app --host "$host" --port "$port"
  popd >/dev/null
}

main "$@"
