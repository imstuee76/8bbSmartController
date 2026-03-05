#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[8bb-ports] %s\n' "$*"
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo "$0" "$@"
  fi
  echo "This script must run as root (or via sudo)." >&2
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw is not installed. Install it first: sudo apt-get install -y ufw" >&2
  exit 1
fi

ports=("$@")
if ((${#ports[@]} == 0)); then
  default_port="${CONTROLLER_SERVER_PORT:-1111}"
  ports=("$default_port")
fi

for p in "${ports[@]}"; do
  if [[ ! "$p" =~ ^[0-9]{2,5}$ ]]; then
    echo "Invalid port: $p" >&2
    exit 1
  fi
  ufw allow "${p}/tcp"
  log "Allowed TCP port ${p}"
done

status="$(ufw status 2>/dev/null || true)"
log "UFW status:"
printf '%s\n' "$status"

if [[ "$status" == *"Status: inactive"* ]]; then
  log "UFW is inactive. Rule is added, but firewall is not enforced until UFW is enabled."
fi

