#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="8bb-controller-server.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
RUN_USER="${SUDO_USER:-$USER}"
RUN_GROUP="$RUN_USER"
BUILD_WEB="1"

log() {
  printf '[8bb-service] %s\n' "$*"
}

run() {
  log "\$ $*"
  "$@"
}

usage() {
  cat <<EOF
Usage: ./linux-controller-install-service.sh [--user <name>] [--group <name>] [--no-build-web]
Installs and enables systemd service: $SERVICE_NAME
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        RUN_USER="${2:-}"
        shift 2
        ;;
      --group)
        RUN_GROUP="${2:-}"
        shift 2
        ;;
      --no-build-web)
        BUILD_WEB="0"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log "ERROR: Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log "ERROR: Run with sudo/root to install systemd service."
    exit 1
  fi
}

write_service_file() {
  cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=8bb Smart Controller Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$APP_ROOT/flasher-web
ExecStart=$APP_ROOT/linux-controller-server.sh
Restart=always
RestartSec=3
Environment=SMART_CONTROLLER_APP_ROOT=$APP_ROOT
Environment=SMART_CONTROLLER_DATA_DIR=$APP_ROOT/data

[Install]
WantedBy=multi-user.target
EOF
}

main() {
  parse_args "$@"
  ensure_root

  run chmod +x \
    "$APP_ROOT/linux-controller-server.sh" \
    "$APP_ROOT/linux-controller-server-control.sh" \
    "$APP_ROOT/linux-flasher-web.sh" \
    "$APP_ROOT/linux-controller-build-web.sh" \
    "$APP_ROOT/linux-controller-mobile.sh" \
    "$APP_ROOT/linux-controller-run.sh" \
    "$APP_ROOT/linux-controller-updater.sh"

  if [[ "$BUILD_WEB" == "1" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      run sudo -u "$RUN_USER" "$APP_ROOT/linux-controller-build-web.sh"
    else
      run su - "$RUN_USER" -s /bin/bash -c "'$APP_ROOT/linux-controller-build-web.sh'"
    fi
  fi

  write_service_file
  run systemctl daemon-reload
  run systemctl enable --now "$SERVICE_NAME"
  run systemctl status "$SERVICE_NAME" --no-pager

  log "Service installed: $SERVICE_PATH"
  log "Mobile URL: http://<linux-ip>:1111/controller/"
  log "API URL: http://<linux-ip>:1111/"
}

main "$@"
