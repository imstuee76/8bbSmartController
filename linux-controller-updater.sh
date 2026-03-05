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
  "flasher-web"
  "esp32-firmware"
  "shared"
  "linux-controller-run.sh"
  "linux-controller-mobile.sh"
  "linux-controller-build-web.sh"
  "linux-controller-server.sh"
  "linux-controller-server-control.sh"
  "linux-flasher-web.sh"
  "linux-controller-install-service.sh"
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

can_run_privileged_noninteractive() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  sudo -n true >/dev/null 2>&1
}

run_maybe_sudo_noninteractive() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    run "$@"
    return 0
  fi
  if can_run_privileged_noninteractive; then
    run sudo "$@"
    return 0
  fi
  return 1
}

apt_update_safe() {
  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi
  if run_maybe_sudo_noninteractive apt-get update; then
    return 0
  fi
  log "WARNING: Skipping apt-get update (requires sudo password in interactive shell)."
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
  if command -v apt-get >/dev/null 2>&1; then
    apt_update_safe || true
    if ! run_maybe_sudo_noninteractive apt-get install -y "$pkg"; then
      log "WARNING: apt install skipped for '$pkg' (sudo password required)."
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

  log "Controller runtime update source: $repo_slug ($branch)"
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
  if [[ -f "$APP_ROOT/linux-controller-mobile.sh" ]]; then
    chmod +x "$APP_ROOT/linux-controller-mobile.sh"
  fi
  if [[ -f "$APP_ROOT/linux-controller-build-web.sh" ]]; then
    chmod +x "$APP_ROOT/linux-controller-build-web.sh"
  fi
  if [[ -f "$APP_ROOT/linux-controller-server.sh" ]]; then
    chmod +x "$APP_ROOT/linux-controller-server.sh"
  fi
  if [[ -f "$APP_ROOT/linux-controller-server-control.sh" ]]; then
    chmod +x "$APP_ROOT/linux-controller-server-control.sh"
  fi
  if [[ -f "$APP_ROOT/linux-flasher-web.sh" ]]; then
    chmod +x "$APP_ROOT/linux-flasher-web.sh"
  fi
  if [[ -f "$APP_ROOT/linux-controller-install-service.sh" ]]; then
    chmod +x "$APP_ROOT/linux-controller-install-service.sh"
  fi
  if [[ -d "$APP_ROOT/scripts" ]]; then
    find "$APP_ROOT/scripts" -type f -name "*.py" -exec chmod +x {} \; || true
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
  local -a target_dirs=("$desktop_dir" "$HOME/Desktop" "$HOME/desktop")

  mkdir -p "$launcher_dir"
  local seen_dirs="|"

  create_one_shortcut() {
    local file_name="$1"
    local title="$2"
    local comment="$3"
    local exec_cmd="$4"
    local terminal="$5"
    local launcher_file="$launcher_dir/$file_name"

    cat >"$launcher_file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$title
Comment=$comment
Exec=$exec_cmd
Path=$APP_ROOT
Terminal=$terminal
Categories=Utility;HomeAutomation;
Icon=preferences-system
StartupNotify=true
EOF
    chmod +x "$launcher_file"

    local copied_any="false"
    for dir in "${target_dirs[@]}"; do
      if [[ -z "$dir" ]]; then
        continue
      fi
      if [[ "$seen_dirs" != *"|$dir|"* ]]; then
        seen_dirs="${seen_dirs}${dir}|"
        mkdir -p "$dir"
      fi
      local desktop_launcher="$dir/$file_name"
      install -m 0755 "$launcher_file" "$desktop_launcher"
      if command -v gio >/dev/null 2>&1; then
        gio set "$desktop_launcher" metadata::trusted true >/dev/null 2>&1 || true
      fi
      copied_any="true"
      log " - Desktop: $desktop_launcher"
    done

    log "Desktop shortcut updated:"
    log " - App menu: $launcher_file"
    if [[ "$copied_any" != "true" ]]; then
      log " - Desktop: not created (no target directory resolved)"
    fi
  }

  create_one_shortcut \
    "8bb-controller.desktop" \
    "8bb Smart Controller" \
    "Run the 8bb Smart Controller app" \
    "$APP_ROOT/linux-controller-run.sh" \
    "false"

  create_one_shortcut \
    "8bb-controller-updater.desktop" \
    "8bb Controller Updater" \
    "Update controller and server files from GitHub" \
    "$APP_ROOT/linux-controller-updater.sh" \
    "true"

  create_one_shortcut \
    "8bb-controller-stop-server.desktop" \
    "8bb Stop Server" \
    "Stop local 8bb server process/service" \
    "$APP_ROOT/linux-controller-server-control.sh stop" \
    "true"

  create_one_shortcut \
    "8bb-flasher-web.desktop" \
    "8bb Flasher Web" \
    "Open flasher web UI (starts temporary backend if needed)" \
    "$APP_ROOT/linux-flasher-web.sh" \
    "true"

  create_one_shortcut \
    "8bb-flasher-stop.desktop" \
    "8bb Flasher Stop" \
    "Stop flasher/backend server process" \
    "$APP_ROOT/linux-controller-server-control.sh stop" \
    "true"
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

ensure_backend_runtime() {
  local req_file="$APP_ROOT/flasher-web/requirements.txt"
  if [[ ! -f "$req_file" ]]; then
    log "WARNING: Backend requirements file missing: $req_file"
    return 0
  fi

  if ! python3 -m pip --version >/dev/null 2>&1; then
    log "python3 pip missing. Installing python3-pip..."
    if command -v apt-get >/dev/null 2>&1; then
      apt_update_safe || true
      if ! run_maybe_sudo_noninteractive apt-get install -y python3-pip; then
        log "WARNING: Could not install python3-pip without sudo prompt."
      fi
    fi
  fi

  if ! python3 -m pip --version >/dev/null 2>&1; then
    log "ERROR: python3 pip is required but unavailable."
    return 1
  fi

  run python3 -m pip install --user --upgrade -r "$req_file"
}

ensure_firewall_rule() {
  local port="${CONTROLLER_SERVER_PORT:-1111}"
  port="$(printf '%s' "$port" | tr -d '[:space:]')"
  if [[ ! "$port" =~ ^[0-9]{2,5}$ ]]; then
    log "Skipping firewall rule: invalid CONTROLLER_SERVER_PORT='$port'"
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    log "UFW not installed; skipping firewall rule setup."
    return 0
  fi

  local status_out
  status_out="$(ufw status 2>/dev/null || true)"
  if [[ -z "$status_out" ]] && can_run_privileged_noninteractive; then
    status_out="$(sudo -n ufw status 2>/dev/null || true)"
  fi
  if [[ "$status_out" == *"Status: inactive"* ]]; then
    log "UFW is inactive; skipping firewall rule setup."
    return 0
  fi
  if [[ "$status_out" != *"Status: active"* ]]; then
    log "Could not determine active UFW status; skipping firewall rule setup."
    return 0
  fi

  if printf '%s\n' "$status_out" | grep -Eq "(^|[[:space:]])${port}/tcp([[:space:]]|$).*ALLOW"; then
    log "Firewall already allows TCP port $port."
    return 0
  fi

  log "Allowing firewall TCP port $port for 8bb server access."
  if ! run_maybe_sudo_noninteractive ufw allow "${port}/tcp"; then
    log "WARNING: Could not add UFW rule without sudo prompt."
    log "Run this once manually: sudo ufw allow ${port}/tcp"
  fi
}

install_deps() {
  ensure_cmd python3 python3
  ensure_cmd curl curl
  ensure_cmd tar tar
  ensure_cmd rsync rsync
  ensure_cmd git git
  if command -v apt-get >/dev/null 2>&1; then
    local -a pkgs=(clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev python3-pip python3-venv python3-serial dfu-util libusb-1.0-0)
    local -a missing=()
    for p in "${pkgs[@]}"; do
      if ! dpkg -s "$p" >/dev/null 2>&1; then
        missing+=("$p")
      fi
    done
    if ((${#missing[@]} > 0)); then
      log "Installing missing Linux build packages: ${missing[*]}"
      apt_update_safe || true
      if ! run_maybe_sudo_noninteractive apt-get install -y "${missing[@]}"; then
        log "WARNING: Optional Linux build package install failed. Flutter may still run if toolchain is already present."
      fi
    fi
  fi

  ensure_flutter
  run "$FLUTTER_BIN" config --enable-linux-desktop
  ensure_linux_desktop_project
  if command -v apt-get >/dev/null 2>&1; then
    if ! command -v onboard >/dev/null 2>&1; then
      log "Installing optional touch keyboard package: onboard"
      apt_update_safe || true
      if ! run_maybe_sudo_noninteractive apt-get install -y onboard; then
        log "WARNING: Could not install onboard automatically without sudo prompt."
        log "Install manually when ready: sudo apt-get install -y onboard"
      fi
    fi
  fi
  ensure_backend_runtime
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

resolve_env_file_for_updates() {
  if [[ -f "$DATA_DIR/.env" ]]; then
    echo "$DATA_DIR/.env"
    return 0
  fi
  if [[ -f "$APP_ROOT/.env" ]]; then
    echo "$APP_ROOT/.env"
    return 0
  fi
  echo "$APP_ROOT/.env"
}

set_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  mkdir -p "$(dirname "$env_file")"
  touch "$env_file"
  local escaped
  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  local line="${key}=\"${escaped}\""
  if grep -Eq "^[[:space:]]*${key}=" "$env_file"; then
    sed -i "s|^[[:space:]]*${key}=.*$|${line}|g" "$env_file"
  else
    printf '%s\n' "$line" >>"$env_file"
  fi
}

detect_idf_script_path() {
  local preferred_root="${IDF_INSTALL_DIR:-$HOME/esp/esp-idf-v5.5.3}"
  if [[ -f "$preferred_root/tools/idf.py" ]]; then
    printf '%s\n' "$preferred_root/tools/idf.py"
    return 0
  fi
  if command -v idf.py >/dev/null 2>&1; then
    local cmd_path
    cmd_path="$(command -v idf.py)"
    if [[ -n "$cmd_path" ]]; then
      printf '%s\n' "$cmd_path"
      return 0
    fi
  fi
  local -a candidates=(
    "$HOME/esp/esp-idf-v5.5.3/tools/idf.py"
    "$HOME/esp/esp-idf/tools/idf.py"
    "$HOME/esp-idf/tools/idf.py"
    "/opt/esp-idf/tools/idf.py"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  local found
  found="$(find "$HOME" -type f -path "*/esp-idf/tools/idf.py" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

detect_idf_python_path() {
  local env_py_path="${IDF_PYTHON_ENV_PATH:-}"
  if [[ -n "$env_py_path" ]]; then
    if [[ -x "$env_py_path/bin/python" ]]; then
      printf '%s\n' "$env_py_path/bin/python"
      return 0
    fi
    if [[ -x "$env_py_path/Scripts/python.exe" ]]; then
      printf '%s\n' "$env_py_path/Scripts/python.exe"
      return 0
    fi
  fi
  local found
  found="$(find "$HOME/.espressif/python_env" -type f -path "*/bin/python" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

detect_idf_python_via_export() {
  local script_path="$1"
  local idf_root
  idf_root="$(cd "$(dirname "$script_path")/.." && pwd)"
  if [[ ! -f "$idf_root/export.sh" ]]; then
    return 1
  fi
  local out
  out="$(bash -lc "source \"$idf_root/export.sh\" >/dev/null 2>&1 && python -c 'import sys; print(sys.executable)'" 2>/dev/null || true)"
  out="$(printf '%s' "$out" | head -n 1 | tr -d '\r')"
  if [[ -n "$out" && -x "$out" ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

is_truthy() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

idf_constraints_file_for_ref() {
  local idf_ref="$1"
  local mm=""
  if [[ "$idf_ref" =~ ^v([0-9]+)\.([0-9]+)(\..*)?$ ]]; then
    mm="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  elif [[ "$idf_ref" =~ ^release/v([0-9]+)\.([0-9]+)$ ]]; then
    mm="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  fi
  if [[ -z "$mm" ]]; then
    echo ""
    return 0
  fi
  echo "$HOME/.espressif/espidf.constraints.v${mm}.txt"
}

install_esp_idf_if_missing() {
  local script_path
  script_path="$(detect_idf_script_path || true)"

  local auto_install="${IDF_AUTO_INSTALL:-1}"
  if ! is_truthy "$auto_install"; then
    log "ESP-IDF missing and auto-install disabled (IDF_AUTO_INSTALL=$auto_install)."
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    ensure_cmd git git || true
  fi
  if ! command -v git >/dev/null 2>&1; then
    log "WARNING: Cannot auto-install ESP-IDF because git is not available."
    return 0
  fi

  local idf_ref="${IDF_INSTALL_REF:-v5.5.3}"
  local idf_root="${IDF_INSTALL_DIR:-$HOME/esp/esp-idf-v5.5.3}"
  local idf_parent
  idf_parent="$(dirname "$idf_root")"
  mkdir -p "$idf_parent"

  if [[ ! -d "$idf_root/.git" ]]; then
    if [[ -e "$idf_root" ]]; then
      log "WARNING: $idf_root exists but is not a git checkout. Skipping auto-clone."
      return 0
    fi
    log "ESP-IDF not found. Auto-installing to: $idf_root (ref=$idf_ref)"
    run git clone --recursive --branch "$idf_ref" https://github.com/espressif/esp-idf.git "$idf_root"
  else
    log "ESP-IDF checkout found at $idf_root"
    local current_ref
    current_ref="$(git -C "$idf_root" describe --tags --exact-match 2>/dev/null || git -C "$idf_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$current_ref" != "$idf_ref" ]]; then
      log "Switching ESP-IDF checkout to $idf_ref (current: ${current_ref:-unknown})"
      run git -C "$idf_root" fetch --tags --prune
      if ! run git -C "$idf_root" checkout -f "$idf_ref"; then
        run git -C "$idf_root" fetch origin "$idf_ref"
        run git -C "$idf_root" checkout -f "$idf_ref"
      fi
    fi
    run git -C "$idf_root" reset --hard
    run git -C "$idf_root" clean -fd
    run git -C "$idf_root" submodule update --init --recursive
  fi

  if [[ ! -x "$idf_root/install.sh" ]]; then
    log "WARNING: ESP-IDF install script not found at $idf_root/install.sh"
    return 0
  fi

  local force_install="${IDF_FORCE_INSTALL:-0}"
  if ! is_truthy "$force_install"; then
    local existing_py
    existing_py="$(detect_idf_python_via_export "$idf_root/tools/idf.py" || true)"
    local constraints_file
    constraints_file="$(idf_constraints_file_for_ref "$idf_ref")"
    if [[ -n "$existing_py" ]] && [[ -n "$constraints_file" ]] && [[ -f "$constraints_file" ]]; then
      log "ESP-IDF tools already available ($existing_py). Skipping install.sh."
      log "Set IDF_FORCE_INSTALL=1 to force re-install."
      return 0
    fi
    if [[ -n "$existing_py" ]] && [[ -n "$constraints_file" ]] && [[ ! -f "$constraints_file" ]]; then
      log "ESP-IDF python found but constraints missing: $constraints_file"
      log "Running install.sh to repair ESP-IDF tool environment."
    fi
  fi

  log "Running ESP-IDF installer (esp32 target, ref=$idf_ref). This may take a while..."
  (
    cd "$idf_root"
    run ./install.sh esp32
  )
}

ensure_esp_idf_ready() {
  install_esp_idf_if_missing

  local script_path
  local preferred_root="${IDF_INSTALL_DIR:-$HOME/esp/esp-idf-v5.5.3}"
  if [[ -f "$preferred_root/tools/idf.py" ]]; then
    script_path="$preferred_root/tools/idf.py"
  else
    script_path="$(detect_idf_script_path || true)"
  fi
  if [[ -z "$script_path" ]]; then
    log "WARNING: ESP-IDF not found on this Linux machine."
    log "Install once with:"
    log "  mkdir -p \$HOME/esp && cd \$HOME/esp"
    log "  git clone --recursive https://github.com/espressif/esp-idf.git"
    log "  cd esp-idf && ./install.sh esp32"
    log "Then rerun updater."
    return 0
  fi

  local py_path
  py_path="$(detect_idf_python_via_export "$script_path" || true)"
  if [[ -z "$py_path" ]]; then
    py_path="$(detect_idf_python_path || true)"
  fi
  if [[ -z "$py_path" ]]; then
    py_path="python3"
  fi
  local idf_cmd="$py_path $script_path"
  export IDF_CMD="$idf_cmd"
  export IDF_PY_PATH="$script_path"
  local py_env_dir
  py_env_dir="$(dirname "$(dirname "$py_path")")"
  if [[ -d "$py_env_dir" ]]; then
    export IDF_PYTHON_ENV_PATH="$py_env_dir"
  fi
  if [[ -d "$HOME/.espressif" ]]; then
    export IDF_TOOLS_PATH="$HOME/.espressif"
  fi

  local env_file
  env_file="$(resolve_env_file_for_updates)"
  set_env_value "$env_file" "IDF_CMD" "$idf_cmd"
  set_env_value "$env_file" "IDF_PY_PATH" "$script_path"
  if [[ -d "$py_env_dir" ]]; then
    set_env_value "$env_file" "IDF_PYTHON_ENV_PATH" "$py_env_dir"
  fi
  if [[ -d "$HOME/.espressif" ]]; then
    set_env_value "$env_file" "IDF_TOOLS_PATH" "$HOME/.espressif"
  fi
  log "ESP-IDF detected and configured:"
  log " - IDF_PY_PATH=$script_path"
  log " - IDF_CMD=$idf_cmd"
  log " - Env file updated: $env_file"
}

resolve_target_owner() {
  local candidate="${SUDO_USER:-${USER:-}}"
  if [[ -z "$candidate" ]]; then
    candidate="$(id -un 2>/dev/null || true)"
  fi
  if [[ -z "$candidate" ]]; then
    echo "arcade"
    return 0
  fi
  echo "$candidate"
}

ensure_runtime_writable_paths() {
  local target_owner
  target_owner="$(resolve_target_owner)"
  local -a paths=(
    "$DATA_DIR"
    "$DATA_DIR/firmware"
    "$DATA_DIR/ota"
    "$DATA_DIR/logs"
    "$APP_ROOT/esp32-firmware"
    "$APP_ROOT/flasher-web"
  )

  for p in "${paths[@]}"; do
    mkdir -p "$p"
  done

  local need_fix="false"
  local p
  for p in "${paths[@]}"; do
    if [[ ! -w "$p" ]]; then
      need_fix="true"
      break
    fi
  done

  if [[ "$need_fix" == "true" ]]; then
    log "Detected non-writable runtime paths. Attempting ownership/permission repair..."
    if id "$target_owner" >/dev/null 2>&1 && run_maybe_sudo_noninteractive chown -R "$target_owner:$target_owner" "$DATA_DIR" "$APP_ROOT/esp32-firmware" "$APP_ROOT/flasher-web"; then
      run_maybe_sudo_noninteractive chmod -R u+rwX "$DATA_DIR" "$APP_ROOT/esp32-firmware" "$APP_ROOT/flasher-web" || true
      log "Runtime path permissions repaired for user: $target_owner"
    else
      log "WARNING: Could not auto-repair permissions without sudo prompt."
      log "Run once manually:"
      log "  sudo chown -R $target_owner:$target_owner \"$DATA_DIR\" \"$APP_ROOT/esp32-firmware\" \"$APP_ROOT/flasher-web\""
      log "  sudo chmod -R u+rwX \"$DATA_DIR\" \"$APP_ROOT/esp32-firmware\" \"$APP_ROOT/flasher-web\""
    fi
  fi
}

ensure_serial_port_access() {
  local target_owner
  target_owner="$(resolve_target_owner)"
  if ! id "$target_owner" >/dev/null 2>&1; then
    log "WARNING: serial access setup skipped (user not found: $target_owner)"
    return 0
  fi

  local current_groups
  current_groups="$(id -nG "$target_owner" 2>/dev/null || true)"
  local -a required_groups=("dialout" "tty")
  local -a missing_groups=()
  local g
  for g in "${required_groups[@]}"; do
    if [[ " $current_groups " != *" $g "* ]]; then
      missing_groups+=("$g")
    fi
  done

  if ((${#missing_groups[@]} > 0)); then
    local group_csv
    group_csv="$(IFS=,; echo "${missing_groups[*]}")"
    if run_maybe_sudo_noninteractive usermod -aG "$group_csv" "$target_owner"; then
      log "Added '$target_owner' to serial groups: $group_csv"
      log "NOTE: Logout/login (or reboot) may be required for new group membership."
    else
      log "WARNING: Could not update serial groups without sudo prompt."
      log "Run once manually: sudo usermod -aG $group_csv $target_owner"
    fi
  else
    log "Serial groups already configured for $target_owner: $current_groups"
  fi

  local rule_path="/etc/udev/rules.d/99-8bb-serial.rules"
  local tmp_rule="$TMP_ROOT/99-8bb-serial.rules"
  cat >"$tmp_rule" <<'EOF'
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", MODE="0660", GROUP="dialout"
SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", MODE="0660", GROUP="dialout"
EOF
  if run_maybe_sudo_noninteractive install -m 0644 "$tmp_rule" "$rule_path"; then
    log "Installed serial udev rule: $rule_path"
    run_maybe_sudo_noninteractive udevadm control --reload-rules || true
    run_maybe_sudo_noninteractive udevadm trigger --subsystem-match=tty || true
  else
    log "WARNING: Could not install udev serial rule without sudo prompt."
    log "Run once manually:"
    log "  sudo install -m 0644 \"$tmp_rule\" \"$rule_path\""
    log "  sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=tty"
  fi

  local found_any="false"
  local dev
  for dev in /dev/ttyUSB* /dev/ttyACM*; do
    if [[ -e "$dev" ]]; then
      found_any="true"
      run_maybe_sudo_noninteractive chgrp dialout "$dev" || true
      run_maybe_sudo_noninteractive chmod g+rw "$dev" || true
    fi
  done
  if [[ "$found_any" == "true" ]]; then
    log "Applied immediate group/write access to connected serial ports."
  else
    log "No /dev/ttyUSB* or /dev/ttyACM* devices currently connected."
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
  create_desktop_shortcut
  ensure_runtime_writable_paths
  install_deps
  ensure_esp_idf_ready
  ensure_serial_port_access
  ensure_firewall_rule
  show_version
  log "Update complete. Preserved: $DATA_DIR and .env files."
}

main "$@"
