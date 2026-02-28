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
FLUTTER_HOME_DEFAULT="$APP_ROOT/.tools/flutter"
FLUTTER_BIN=""

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

  FLUTTER_BIN=""
  return 1
}

ensure_flutter() {
  if resolve_flutter; then
    log "Using Flutter: $FLUTTER_BIN"
    return 0
  fi

  if [[ -x "$APP_ROOT/linux-controller-updater.sh" ]]; then
    log "Flutter missing. Running updater to install prerequisites."
    run "$APP_ROOT/linux-controller-updater.sh"
    if resolve_flutter; then
      log "Using Flutter after updater: $FLUTTER_BIN"
      return 0
    fi
  fi

  log "ERROR: Flutter is required but was not found. Run ./linux-controller-updater.sh and try again."
  exit 1
}

ensure_linux_desktop_project() {
  local app_dir="$APP_ROOT/controller-app"
  local linux_cmake="$app_dir/linux/CMakeLists.txt"
  if [[ -f "$linux_cmake" ]]; then
    return 0
  fi

  log "Linux desktop project files missing. Creating linux platform support..."
  pushd "$app_dir" >/dev/null
  run "$FLUTTER_BIN" create --platforms=linux .
  popd >/dev/null
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
  ensure_flutter
  ensure_linux_desktop_project

  pushd "$APP_ROOT/controller-app" >/dev/null
  run "$FLUTTER_BIN" pub get
  run "$FLUTTER_BIN" run -d linux --target lib/main.dart "$@"
  popd >/dev/null
}

main "$@"
