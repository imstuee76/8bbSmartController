#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
LOG_BASE="$DATA_DIR/logs/updater/sessions"
DAY_UTC="$(date -u +%Y%m%d)"
SESSION_ID="updater-$(date -u +%Y%m%dT%H%M%SZ)-$$"
SESSION_DIR="$LOG_BASE/$SESSION_ID"
ACTIVITY_LOG="$SESSION_DIR/activity-$DAY_UTC.log"
ERROR_LOG="$SESSION_DIR/errors-$DAY_UTC.log"

mkdir -p "$SESSION_DIR"
mkdir -p "$DATA_DIR/logs/controller"

exec > >(tee -a "$ACTIVITY_LOG")
exec 2> >(tee -a "$ERROR_LOG" >&2)

log() {
  printf '[8bb-updater] %s\n' "$*"
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
  else
    log "No .env file found in $DATA_DIR or $APP_ROOT"
  fi
}

ensure_cmd() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  log "Missing command '$cmd'. Attempting apt install: $pkg"
  if command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    run sudo apt-get update
    run sudo apt-get install -y "$pkg"
  fi
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: command '$cmd' is still unavailable after install attempt."
    return 1
  fi
}

ensure_permissions() {
  chmod +x "$APP_ROOT/linux-controller-updater.sh" "$APP_ROOT/linux-controller-run.sh" || true
  if [[ -d "$APP_ROOT/scripts" ]]; then
    find "$APP_ROOT/scripts" -type f -name "*.py" -exec chmod +x {} \; || true
  fi
}

pull_latest() {
  if [[ ! -d "$APP_ROOT/.git" ]]; then
    log "ERROR: .git not found in $APP_ROOT. Clone repo first, then rerun updater."
    return 1
  fi
  local branch="${GIT_BRANCH:-}"
  if [[ -z "$branch" ]]; then
    branch="$(git -C "$APP_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    branch="main"
  fi
  run git -C "$APP_ROOT" fetch origin "$branch"
  run git -C "$APP_ROOT" pull --ff-only origin "$branch"
}

install_deps() {
  ensure_cmd git git
  ensure_cmd python3 python3
  if ! command -v flutter >/dev/null 2>&1; then
    log "ERROR: Flutter is required but not found in PATH."
    log "Install Flutter SDK and add it to PATH, then rerun updater."
    return 1
  fi
  run flutter config --enable-linux-desktop
  pushd "$APP_ROOT/controller-app" >/dev/null
  run flutter pub get
  popd >/dev/null
}

show_version() {
  local version_file="$APP_ROOT/shared/version.json"
  if [[ -f "$version_file" ]]; then
    log "Version manifest:"
    cat "$version_file"
  else
    log "Version manifest missing at $version_file"
  fi
}

main() {
  log "Session: $SESSION_ID"
  log "App root: $APP_ROOT"
  log "Data dir: $DATA_DIR"
  log "Activity log: $ACTIVITY_LOG"
  log "Error log: $ERROR_LOG"
  mkdir -p "$DATA_DIR"
  load_env_file
  ensure_permissions
  pull_latest
  install_deps
  show_version
  log "Updater completed successfully."
}

main "$@"
