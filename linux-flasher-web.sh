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
  while ((i < 50)); do
    if command -v curl >/dev/null 2>&1; then
      if curl -fsS "${url}api/auth/status" >/dev/null 2>&1; then
        log "Flasher backend ready: $url"
        return 0
      fi
    else
      sleep 1
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  log "Flasher readiness check timed out; opening browser anyway."
}

main() {
  log "Session: $SESSION_ID"
  log "App root: $APP_ROOT"
  log "Data dir: $DATA_DIR"

  if [[ ! -x "$APP_ROOT/linux-controller-server-control.sh" ]]; then
    log "ERROR: Missing server control script: $APP_ROOT/linux-controller-server-control.sh"
    exit 1
  fi

  run "$APP_ROOT/linux-controller-server-control.sh" start

  local base_url
  base_url="$(resolve_browser_url)"
  wait_for_server "$base_url"
  open_browser "$base_url"
  log "Opened flasher UI: $base_url"
}

main "$@"
