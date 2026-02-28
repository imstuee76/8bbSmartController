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
TMP_ROOT="$(mktemp -d)"

CONTROLLER_SYNC_PATHS=(
  "controller-app"
  "shared"
  "linux-controller-run.sh"
  "linux-controller-updater.sh"
  ".env.example"
  "README.md"
)

mkdir -p "$SESSION_DIR"
mkdir -p "$DATA_DIR/logs/controller"

exec > >(tee -a "$ACTIVITY_LOG")
exec 2> >(tee -a "$ERROR_LOG" >&2)

cleanup() {
  rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

resolve_repo_slug() {
  local repo="${GITHUB_REPO:-}"
  local repo_name="${GITHUB_REPO_NAME:-8bbSmartController}"
  if [[ -z "$repo" ]]; then
    echo "imstuee76/8bbSmartController"
    return 0
  fi
  if [[ "$repo" == *"/"* ]]; then
    echo "$repo"
    return 0
  fi
  echo "$repo/$repo_name"
}

download_archive() {
  local repo_slug="$1"
  local branch="$2"
  local out="$3"
  local url="https://api.github.com/repos/${repo_slug}/tarball/${branch}"
  local -a curl_cmd=(curl -fL --retry 3 --retry-delay 2 -o "$out")
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_cmd+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl_cmd+=(-H "Accept: application/vnd.github+json" "$url")
  run "${curl_cmd[@]}"
}

sync_path() {
  local src_root="$1"
  local rel="$2"
  local src="$src_root/$rel"
  local dst="$APP_ROOT/$rel"
  if [[ ! -e "$src" ]]; then
    log "Skip missing path in update bundle: $rel"
    return 0
  fi
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    run rsync -a --delete "$src/" "$dst/"
  else
    mkdir -p "$(dirname "$dst")"
    run install -m 0644 "$src" "$dst"
  fi
}

sync_controller_files() {
  local repo_slug
  repo_slug="$(resolve_repo_slug)"
  local branch="${GIT_BRANCH:-main}"
  local archive="$TMP_ROOT/repo.tar.gz"
  local extract="$TMP_ROOT/extract"
  mkdir -p "$extract"

  log "Controller-only update source: $repo_slug ($branch)"
  download_archive "$repo_slug" "$branch" "$archive"
  run tar -xzf "$archive" -C "$extract"

  local src_root
  src_root="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$src_root" || ! -d "$src_root" ]]; then
    log "ERROR: Could not locate extracted source folder."
    return 1
  fi

  for rel in "${CONTROLLER_SYNC_PATHS[@]}"; do
    sync_path "$src_root" "$rel"
  done
}

ensure_permissions() {
  if [[ -f "$APP_ROOT/linux-controller-updater.sh" ]]; then
    chmod +x "$APP_ROOT/linux-controller-updater.sh"
  fi
  if [[ -f "$APP_ROOT/linux-controller-run.sh" ]]; then
    chmod +x "$APP_ROOT/linux-controller-run.sh"
  fi
  if [[ -d "$APP_ROOT/scripts" ]]; then
    find "$APP_ROOT/scripts" -type f -name "*.py" -exec chmod +x {} \; || true
  fi
}

install_deps() {
  ensure_cmd python3 python3
  ensure_cmd curl curl
  ensure_cmd tar tar
  ensure_cmd rsync rsync
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
  ensure_cmd curl curl
  ensure_cmd tar tar
  ensure_cmd rsync rsync
  sync_controller_files
  ensure_permissions
  install_deps
  show_version
  log "Update complete. Preserved: $DATA_DIR and .env files."
}

main "$@"
