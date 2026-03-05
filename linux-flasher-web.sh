#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
LOG_BASE="$DATA_DIR/logs/flasher-launch/sessions"
DAY_LOCAL="$(date +%Y%m%d)"
SESSION_STAMP="$(date +%Y%m%dT%H%M%S%z)"
SESSION_ID="flasher-launch-${SESSION_STAMP}-$$"
SESSION_DIR="$LOG_BASE/$SESSION_ID"
ACTIVITY_LOG="$SESSION_DIR/activity-$DAY_LOCAL.log"
ERROR_LOG="$SESSION_DIR/errors-$DAY_LOCAL.log"

mkdir -p "$SESSION_DIR"

exec > >(tee -a "$ACTIVITY_LOG")
exec 2> >(tee -a "$ERROR_LOG" >&2)

log() {
  printf '[8bb-flasher] %s\n' "$*"
}

run() {
  log "\$ $*"
  "$@"
}

TRANSIENT_PID=""

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

resolve_browser_url() {
  local host="${CONTROLLER_SERVER_HOST:-127.0.0.1}"
  local port="${CONTROLLER_SERVER_PORT:-1111}"
  host="$(printf '%s' "$host" | tr -d '[:space:]')"
  port="$(printf '%s' "$port" | tr -d '[:space:]')"

  if [[ -z "$host" || "$host" == "0.0.0.0" || "$host" == "::" ]]; then
    host="127.0.0.1"
  fi
  if [[ -z "$port" ]]; then
    port="1111"
  fi
  printf 'http://%s:%s/\n' "$host" "$port"
}

is_backend_ready() {
  local base_url="$1"
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if curl -fsS --connect-timeout 1 --max-time 2 "${base_url}api/auth/status" >/dev/null 2>&1; then
    return 0
  fi
  if curl -fsS --connect-timeout 1 --max-time 2 "${base_url}" >/dev/null 2>&1; then
    return 0
  fi
  if curl -fsS --connect-timeout 1 --max-time 2 "${base_url}ui/" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

detect_backend_url() {
  local configured
  configured="$(resolve_browser_url)"
  if is_backend_ready "$configured"; then
    printf '%s\n' "$configured"
    return 0
  fi

  local host="${CONTROLLER_SERVER_HOST:-127.0.0.1}"
  host="$(printf '%s' "$host" | tr -d '[:space:]')"
  if [[ -z "$host" || "$host" == "0.0.0.0" || "$host" == "::" ]]; then
    host="127.0.0.1"
  fi

  local -a fallback_ports=(1111 8088)
  local p
  for p in "${fallback_ports[@]}"; do
    local candidate="http://${host}:${p}/"
    if is_backend_ready "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '%s\n' "$configured"
}

open_browser() {
  local url="$1"
  if command -v xdg-open >/dev/null 2>&1; then
    (xdg-open "$url" >/dev/null 2>&1 & disown) || true
    return 0
  fi
  if command -v gio >/dev/null 2>&1; then
    (gio open "$url" >/dev/null 2>&1 & disown) || true
    return 0
  fi
  if command -v sensible-browser >/dev/null 2>&1; then
    (sensible-browser "$url" >/dev/null 2>&1 & disown) || true
    return 0
  fi
  log "No browser opener found (xdg-open/gio/sensible-browser). URL: $url"
}

wait_for_server() {
  local url="$1"
  local i=0
  while ((i < 120)); do
    if is_backend_ready "$url"; then
      log "Flasher backend ready: $url"
      return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
      sleep 1
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_for_any_server() {
  local preferred="$1"
  local max_loops="${2:-120}"
  local host="${CONTROLLER_SERVER_HOST:-127.0.0.1}"
  host="$(printf '%s' "$host" | tr -d '[:space:]')"
  if [[ -z "$host" || "$host" == "0.0.0.0" || "$host" == "::" ]]; then
    host="127.0.0.1"
  fi
  local port="${CONTROLLER_SERVER_PORT:-1111}"
  port="$(printf '%s' "$port" | tr -d '[:space:]')"
  if [[ -z "$port" ]]; then
    port="1111"
  fi

  local -a urls=(
    "$preferred"
    "http://${host}:${port}/"
    "http://127.0.0.1:${port}/"
    "http://localhost:${port}/"
    "http://${host}:1111/"
    "http://${host}:8088/"
    "http://127.0.0.1:1111/"
    "http://127.0.0.1:8088/"
  )

  local i=0
  while ((i < max_loops)); do
    local u
    for u in "${urls[@]}"; do
      if is_backend_ready "$u"; then
        printf '%s\n' "$u"
        return 0
      fi
    done
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

print_server_debug() {
  log "Backend did not become ready."
  if [[ -x "$APP_ROOT/linux-controller-server-control.sh" ]]; then
    "$APP_ROOT/linux-controller-server-control.sh" status || true
    "$APP_ROOT/linux-controller-server-control.sh" logs 80 || true
  fi
  log "Check dependencies were installed by updater:"
  log "  ./linux-controller-updater.sh"
  log "Then retry:"
  log "  ./linux-flasher-web.sh"
}

start_transient_backend() {
  local host="${CONTROLLER_SERVER_HOST:-0.0.0.0}"
  local port="${CONTROLLER_SERVER_PORT:-1111}"
  local web_dir="${CONTROLLER_WEB_DIR:-$APP_ROOT/controller-app/build/web}"
  host="$(printf '%s' "$host" | tr -d '[:space:]')"
  port="$(printf '%s' "$port" | tr -d '[:space:]')"
  if [[ -z "$host" ]]; then
    host="0.0.0.0"
  fi
  if [[ -z "$port" ]]; then
    port="1111"
  fi

  export SMART_CONTROLLER_DATA_DIR="$DATA_DIR"
  export SMART_CONTROLLER_APP_ROOT="$APP_ROOT"
  export CONTROLLER_WEB_DIR="$web_dir"

  log "Starting transient backend in this terminal (host=$host port=$port)"
  run python3 -m uvicorn app.main:app --app-dir "$APP_ROOT/flasher-web" --host "$host" --port "$port" &
  TRANSIENT_PID="$!"
  log "Transient backend pid=$TRANSIENT_PID"
}

stop_transient_backend() {
  if [[ -n "${TRANSIENT_PID:-}" ]] && kill -0 "$TRANSIENT_PID" >/dev/null 2>&1; then
    log "Stopping transient backend pid=$TRANSIENT_PID"
    kill "$TRANSIENT_PID" >/dev/null 2>&1 || true
    sleep 0.5
    if kill -0 "$TRANSIENT_PID" >/dev/null 2>&1; then
      kill -9 "$TRANSIENT_PID" >/dev/null 2>&1 || true
    fi
  fi
}

main() {
  log "Session: $SESSION_ID"
  log "App root: $APP_ROOT"
  log "Data dir: $DATA_DIR"
  load_env_file
  trap stop_transient_backend EXIT INT TERM

  local base_url
  base_url="$(detect_backend_url)"
  log "Checking for existing backend..."
  if base_url="$(wait_for_any_server "$base_url" 8)"; then
    log "Flasher backend ready: $base_url"
    open_browser "$base_url"
    log "Opened flasher UI (existing backend): $base_url"
    return 0
  fi

  log "No existing backend found quickly; starting temporary backend."
  start_transient_backend
  base_url="$(resolve_browser_url)"
  if ! base_url="$(wait_for_any_server "$base_url")"; then
    print_server_debug
    exit 1
  fi

  log "Flasher backend ready: $base_url"
  open_browser "$base_url"
  log "Opened flasher UI: $base_url"
  log "Close this terminal (or press Ctrl+C) to stop flasher backend."
  wait "$TRANSIENT_PID"
}

main "$@"
