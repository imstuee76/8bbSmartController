#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SMART_CONTROLLER_DATA_DIR:-$APP_ROOT/data}"
LOG_BASE="$DATA_DIR/logs/updater/sessions"
DAY_LOCAL="$(date +%Y%m%d)"
SESSION_STAMP="$(date +%Y%m%dT%H%M%S%z)"
SESSION_ID="updater-${SESSION_STAMP}-$$"
SESSION_DIR="$LOG_BASE/$SESSION_ID"
ACTIVITY_LOG="$SESSION_DIR/activity-$DAY_LOCAL.log"
ERROR_LOG="$SESSION_DIR/errors-$DAY_LOCAL.log"
TMP_ROOT="$(mktemp -d)"
FLUTTER_HOME_DEFAULT="$APP_ROOT/.tools/flutter"
FLUTTER_BIN=""

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

sanitize_log_text() {
  local text="$*"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    text="${text//${GITHUB_TOKEN}/***REDACTED***}"
  fi
  printf '%s' "$text"
}

run() {
  local safe_cmd
  safe_cmd="$(sanitize_log_text "$*")"
  log "\$ $safe_cmd"
  "$@"
}

apt_update_safe() {
  if ! command -v sudo >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi
  if run sudo apt-get update; then
    return 0
  fi
  log "WARNING: apt-get update failed (likely broken external repo). Continuing with best effort."
  return 1
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
    apt_update_safe || true
    if ! run sudo apt-get install -y "$pkg"; then
      log "WARNING: apt install failed for '$pkg'."
    fi
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

ensure_linux_desktop_project() {
  local app_dir="$APP_ROOT/controller-app"
  local linux_cmake="$app_dir/linux/CMakeLists.txt"
  if [[ -f "$linux_cmake" ]]; then
    return 0
  fi

  log "Linux desktop project files missing. Bootstrapping Flutter linux platform..."
  pushd "$app_dir" >/dev/null
  run "$FLUTTER_BIN" create --platforms=linux .
  popd >/dev/null
}

install_deps() {
  ensure_cmd python3 python3
  ensure_cmd curl curl
  ensure_cmd tar tar
  ensure_cmd rsync rsync
  if command -v apt-get >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    local -a pkgs=(clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev)
    local -a missing=()
    for p in "${pkgs[@]}"; do
      if ! dpkg -s "$p" >/dev/null 2>&1; then
        missing+=("$p")
      fi
    done
    if ((${#missing[@]} > 0)); then
      log "Installing missing Linux build packages: ${missing[*]}"
      apt_update_safe || true
      if ! run sudo apt-get install -y "${missing[@]}"; then
        log "WARNING: Optional Linux build package install failed. Flutter may still run if toolchain is already present."
      fi
    fi
  fi

  ensure_flutter
  run "$FLUTTER_BIN" config --enable-linux-desktop
  ensure_linux_desktop_project
  pushd "$APP_ROOT/controller-app" >/dev/null
  run "$FLUTTER_BIN" pub get
  popd >/dev/null
}

ensure_flutter() {
  local flutter_home="${FLUTTER_HOME:-$FLUTTER_HOME_DEFAULT}"
  local flutter_bin="$flutter_home/bin/flutter"

  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
    log "Using Flutter from PATH: $FLUTTER_BIN"
  elif [[ -x "$flutter_bin" ]]; then
    FLUTTER_BIN="$flutter_bin"
    log "Using local Flutter SDK: $FLUTTER_BIN"
  else
    log "Flutter not found. Downloading local Flutter SDK..."
    local releases_json="$TMP_ROOT/flutter_releases_linux.json"
    local sdk_archive="$TMP_ROOT/flutter_linux_stable.tar.xz"
    run curl -fL -o "$releases_json" "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json"

    local release_info
    release_info="$(python3 - "$releases_json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fp:
    data = json.load(fp)
base_url = data.get("base_url", "").rstrip("/")
current_hash = data.get("current_release", {}).get("stable", "")
archive = ""
for item in data.get("releases", []):
    if item.get("hash") == current_hash:
        archive = item.get("archive", "")
        break
if not base_url or not archive:
    raise SystemExit("Could not resolve Flutter stable archive URL")
print(base_url + "/" + archive)
PY
)"
    if [[ -z "$release_info" ]]; then
      log "ERROR: Could not resolve Flutter stable release URL."
      return 1
    fi
    run curl -fL -o "$sdk_archive" "$release_info"
    mkdir -p "$APP_ROOT/.tools"
    run tar -xJf "$sdk_archive" -C "$APP_ROOT/.tools"
    FLUTTER_BIN="$flutter_bin"
    if [[ ! -x "$FLUTTER_BIN" ]]; then
      log "ERROR: Flutter install failed at $FLUTTER_BIN"
      return 1
    fi
    log "Installed local Flutter SDK at $flutter_home"
  fi

  export PATH="$(dirname "$FLUTTER_BIN"):$PATH"
  run "$FLUTTER_BIN" --version
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
