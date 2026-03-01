#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
LOG_BASE="$DATA_DIR/logs/controller/sessions"
DAY_LOCAL="$(date +%Y%m%d)"
SESSION_STAMP="$(date +%Y%m%dT%H%M%S%z)"
SESSION_ID="controller-${SESSION_STAMP}-$$"
SESSION_DIR="$LOG_BASE/$SESSION_ID"
ACTIVITY_LOG="$SESSION_DIR/activity-$DAY_LOCAL.log"
ERROR_LOG="$SESSION_DIR/errors-$DAY_LOCAL.log"
FLUTTER_HOME_DEFAULT="$APP_ROOT/.tools/flutter"
FLUTTER_BIN=""
ENV_FILE_LOADED=""
BACKEND_PID=""
BACKEND_ACTIVITY_LOG="$SESSION_DIR/backend-$DAY_LOCAL.log"
BACKEND_ERROR_LOG="$SESSION_DIR/backend-errors-$DAY_LOCAL.log"

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

is_true() {
  local raw="${1:-}"
  local v
  v="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

cleanup_backend() {
  if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
    log "Stopping local backend (pid=$BACKEND_PID)"
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
    wait "$BACKEND_PID" >/dev/null 2>&1 || true
    BACKEND_PID=""
  fi
}

trap cleanup_backend EXIT INT TERM

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

ensure_python_pip() {
  if python3 -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    log "python3 pip missing. Installing python3-pip..."
    run sudo apt-get update || true
    run sudo apt-get install -y python3-pip || true
  fi

  if ! python3 -m pip --version >/dev/null 2>&1; then
    log "ERROR: python3 pip is required for local backend but unavailable."
    return 1
  fi
}

load_env_file() {
  local env_file=""
  if [[ -f "$DATA_DIR/.env" ]]; then
    env_file="$DATA_DIR/.env"
  elif [[ -f "$APP_ROOT/.env" ]]; then
    env_file="$APP_ROOT/.env"
  fi
  if [[ -n "$env_file" ]]; then
    ENV_FILE_LOADED="$env_file"
    export SMART_CONTROLLER_ENV_FILE="$env_file"
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

create_desktop_shortcut() {
  local desktop_dir="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
  if command -v xdg-user-dir >/dev/null 2>&1; then
    local detected_desktop
    detected_desktop="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    if [[ -n "$detected_desktop" ]]; then
      desktop_dir="$detected_desktop"
    fi
  fi

  local launcher_dir="$HOME/.local/share/applications"
  local launcher_file="$launcher_dir/8bb-controller.desktop"
  local -a target_dirs=("$desktop_dir" "$HOME/Desktop" "$HOME/desktop")

  mkdir -p "$launcher_dir"
  cat >"$launcher_file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=8bb Smart Controller
Comment=Run the 8bb Smart Controller app
Exec=$APP_ROOT/linux-controller-run.sh
Path=$APP_ROOT
Terminal=false
Categories=Utility;HomeAutomation;
Icon=preferences-system
StartupNotify=true
EOF
  chmod +x "$launcher_file"

  local copied_any="false"
  local seen_dirs="|"
  for dir in "${target_dirs[@]}"; do
    if [[ -z "$dir" ]]; then
      continue
    fi
    if [[ "$seen_dirs" == *"|$dir|"* ]]; then
      continue
    fi
    seen_dirs="${seen_dirs}${dir}|"
    mkdir -p "$dir"
    local target_file="$dir/8bb-controller.desktop"
    cp "$launcher_file" "$target_file"
    chmod +x "$target_file"
    if command -v gio >/dev/null 2>&1; then
      gio set "$target_file" metadata::trusted true >/dev/null 2>&1 || true
    fi
    copied_any="true"
    log "Desktop shortcut: $target_file"
  done

  if [[ "$copied_any" == "true" ]]; then
    log "App launcher: $launcher_file"
  fi
}

ensure_local_backend_deps() {
  local req_file="$APP_ROOT/flasher-web/requirements.txt"
  if [[ ! -f "$req_file" ]]; then
    log "ERROR: Missing local backend requirements: $req_file"
    log "Run ./linux-controller-updater.sh to sync controller runtime files."
    return 1
  fi
  ensure_python_pip
  run python3 -m pip install --user --upgrade -r "$req_file"
}

wait_for_local_backend() {
  local base_url="$1"
  if ! command -v curl >/dev/null 2>&1; then
    log "curl not found; skipping local backend readiness check."
    return 0
  fi

  local i=0
  while ((i < 40)); do
    if curl -fsS "${base_url}/api/auth/status" >/dev/null 2>&1; then
      log "Local backend ready: ${base_url}"
      return 0
    fi
    if [[ -n "$BACKEND_PID" ]] && ! kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
      log "ERROR: Local backend process exited unexpectedly."
      if [[ -f "$BACKEND_ERROR_LOG" ]]; then
        log "Last backend errors:"
        tail -n 30 "$BACKEND_ERROR_LOG" || true
      fi
      return 1
    fi
    sleep 0.25
    i=$((i + 1))
  done

  log "WARNING: Local backend readiness timed out; continuing startup."
  return 0
}

start_local_backend() {
  local use_local_raw="${CONTROLLER_USE_LOCAL_BACKEND:-1}"
  if ! is_true "$use_local_raw"; then
    log "Local backend disabled by CONTROLLER_USE_LOCAL_BACKEND=$use_local_raw"
    return 0
  fi

  local backend_dir="$APP_ROOT/flasher-web"
  if [[ ! -d "$backend_dir" ]]; then
    log "ERROR: Local backend folder missing: $backend_dir"
    log "Run ./linux-controller-updater.sh first."
    return 1
  fi

  local host="${CONTROLLER_LOCAL_BACKEND_HOST:-127.0.0.1}"
  local port="${CONTROLLER_LOCAL_BACKEND_PORT:-8088}"
  local reload_flag=""
  if is_true "${CONTROLLER_LOCAL_BACKEND_RELOAD:-0}"; then
    reload_flag="--reload"
  fi

  local base_url="http://${host}:${port}"
  export CONTROLLER_BACKEND_URL="$base_url"
  export SMART_CONTROLLER_BACKEND_URL="$base_url"

  if command -v curl >/dev/null 2>&1; then
    if curl -fsS "${base_url}/api/auth/status" >/dev/null 2>&1; then
      log "Local backend already running: $base_url"
      return 0
    fi
  fi

  ensure_local_backend_deps

  log "Starting local backend: $base_url"
  (
    cd "$backend_dir"
    if [[ -n "$reload_flag" ]]; then
      exec python3 -m uvicorn app.main:app --host "$host" --port "$port" --reload
    else
      exec python3 -m uvicorn app.main:app --host "$host" --port "$port"
    fi
  ) >>"$BACKEND_ACTIVITY_LOG" 2>>"$BACKEND_ERROR_LOG" &
  BACKEND_PID=$!
  log "Local backend pid: $BACKEND_PID"
  log "Backend logs: $BACKEND_ACTIVITY_LOG | $BACKEND_ERROR_LOG"

  wait_for_local_backend "$base_url"
}

main() {
  log "Session: $SESSION_ID"
  log "App root: $APP_ROOT"
  log "Data dir: $DATA_DIR"
  export SMART_CONTROLLER_DATA_DIR="$DATA_DIR"
  export SMART_CONTROLLER_APP_ROOT="$APP_ROOT"
  load_env_file
  if [[ -z "$ENV_FILE_LOADED" && -f "$APP_ROOT/.env" ]]; then
    export SMART_CONTROLLER_ENV_FILE="$APP_ROOT/.env"
  fi
  start_local_backend
  if [[ -n "${CONTROLLER_BACKEND_URL:-}" ]]; then
    log "Configured backend URL: ${CONTROLLER_BACKEND_URL}"
  else
    log "WARNING: CONTROLLER_BACKEND_URL not set. App may fall back to localhost."
  fi
  create_desktop_shortcut
  ensure_flutter
  ensure_linux_desktop_project

  pushd "$APP_ROOT/controller-app" >/dev/null
  run "$FLUTTER_BIN" pub get
  run "$FLUTTER_BIN" run -d linux --target lib/main.dart "$@"
  popd >/dev/null
}

main "$@"
