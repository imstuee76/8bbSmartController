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

RULE_PATH="/etc/udev/rules.d/99-8bb-serial.rules"
SERIAL_MODE="${SERIAL_MODE:-0666}"
TARGET_USER="${1:-${SUDO_USER:-${USER:-arcade}}}"

cat >"$RULE_PATH" <<EOF
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", MODE="$SERIAL_MODE", GROUP="dialout", TAG+="uaccess"
SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", MODE="$SERIAL_MODE", GROUP="dialout", TAG+="uaccess"
EOF
log "Installed udev rule: $RULE_PATH (MODE=$SERIAL_MODE)"

if id "$TARGET_USER" >/dev/null 2>&1; then
  groups_to_add=()
  for g in dialout tty uucp plugdev lock; do
    if getent group "$g" >/dev/null 2>&1; then
      groups_to_add+=("$g")
    fi
  done
  if ((${#groups_to_add[@]} > 0)); then
    usermod -aG "$(IFS=,; echo "${groups_to_add[*]}")" "$TARGET_USER" || true
    log "Ensured user '$TARGET_USER' is in groups: ${groups_to_add[*]}"
  fi
fi

udevadm control --reload-rules
udevadm trigger --subsystem-match=tty || true

if command -v setfacl >/dev/null 2>&1 && id "$TARGET_USER" >/dev/null 2>&1; then
  for dev in /dev/ttyUSB* /dev/ttyACM*; do
    if [[ -e "$dev" ]]; then
      setfacl -m "u:${TARGET_USER}:rw" "$dev" || true
    fi
  done
fi

log "Done. Replug USB serial device."
log "If access still denied, logout/login (or reboot) once."

