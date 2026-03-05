#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
RUN_DIR="$DATA_DIR/run"
PID_FILE="$RUN_DIR/controller-server.pid"
SERVICE_NAME="${CONTROLLER_SERVER_SERVICE_NAME:-8bb-controller-server.service}"

log() {
  printf '[8bb-serverctl] %s\n' "$*"
}

run() {
  log "\$ $*"
  "$@"
}

run_maybe_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    run "$@"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    run sudo "$@"
    return 0
  fi
  run "$@"
}

service_exists() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$SERVICE_NAME"
}

service_active() {
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME"
}

manual_pid() {
  if [[ -f "$PID_FILE" ]]; then
    cat "$PID_FILE" 2>/dev/null || true
  fi
}

manual_status() {
  local pid
  pid="$(manual_pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    log "Manual server is running (pid=$pid)"
    return 0
  fi
  if [[ -n "$pid" ]]; then
    rm -f "$PID_FILE" || true
  fi
  local found
  found="$(pgrep -af "uvicorn app.main:app" | grep "$APP_ROOT/flasher-web" || true)"
  if [[ -n "$found" ]]; then
    log "Manual server processes found:"
    printf '%s\n' "$found"
    return 0
  fi
  log "Manual server is not running."
  return 1
}

manual_start() {
  if manual_status >/dev/null 2>&1; then
    log "Manual server already running."
    return 0
  fi
  mkdir -p "$RUN_DIR"
  local day
  day="$(date +%Y%m%d)"
  local log_dir="$DATA_DIR/logs/server/manual"
  mkdir -p "$log_dir"
  local activity="$log_dir/activity-$day.log"
  local errors="$log_dir/errors-$day.log"

  (
    cd "$APP_ROOT"
    nohup "$APP_ROOT/linux-controller-server.sh" >>"$activity" 2>>"$errors" &
    echo "$!" >"$PID_FILE"
  )
  local pid
  pid="$(manual_pid)"
  log "Manual server started (pid=$pid)"
  log "Manual logs: $activity | $errors"
}

manual_stop() {
  local pid
  pid="$(manual_pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    log "Stopping manual server pid=$pid"
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    if kill -0 "$pid" >/dev/null 2>&1; then
      log "Force stopping manual server pid=$pid"
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$PID_FILE" || true
    return 0
  fi

  local pids
  pids="$(pgrep -f "uvicorn app.main:app.*--port 1111" || true)"
  if [[ -n "$pids" ]]; then
    log "Stopping uvicorn pids: $pids"
    kill $pids >/dev/null 2>&1 || true
    return 0
  fi
  log "No manual server process found."
}

usage() {
  cat <<EOF
Usage: ./linux-controller-server-control.sh <start|stop|restart|status|logs>

If systemd service '$SERVICE_NAME' exists, this script controls that service.
Otherwise it controls a manual server process started from this script.
EOF
}

main() {
  local action="${1:-status}"
  local lines="${2:-80}"

  case "$action" in
    start)
      if service_exists; then
        if run_maybe_sudo systemctl start "$SERVICE_NAME"; then
          run systemctl status "$SERVICE_NAME" --no-pager || true
        else
          log "Service start failed (likely permissions). Falling back to manual server start."
          manual_start
        fi
      else
        manual_start
      fi
      ;;
    stop)
      if service_exists; then
        run_maybe_sudo systemctl stop "$SERVICE_NAME"
        run systemctl status "$SERVICE_NAME" --no-pager || true
      else
        manual_stop
      fi
      ;;
    restart)
      if service_exists; then
        run_maybe_sudo systemctl restart "$SERVICE_NAME"
        run systemctl status "$SERVICE_NAME" --no-pager || true
      else
        manual_stop
        manual_start
      fi
      ;;
    status)
      if service_exists; then
        run systemctl status "$SERVICE_NAME" --no-pager || true
        if service_active; then
          log "Service is active."
        else
          log "Service is not active."
        fi
      else
        manual_status || true
      fi
      ;;
    logs)
      if service_exists; then
        run_maybe_sudo journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager
      else
        local day
        day="$(date +%Y%m%d)"
        local log_dir="$DATA_DIR/logs/server/manual"
        local activity="$log_dir/activity-$day.log"
        local errors="$log_dir/errors-$day.log"
        log "Manual logs:"
        log "  $activity"
        log "  $errors"
        if [[ -f "$activity" ]]; then
          tail -n "$lines" "$activity" || true
        fi
        if [[ -f "$errors" ]]; then
          tail -n "$lines" "$errors" || true
        fi
      fi
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      log "ERROR: Unknown action '$action'"
      usage
      exit 1
      ;;
  esac
}

main "$@"
