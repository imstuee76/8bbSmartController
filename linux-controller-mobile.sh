#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER_SERVER_HOST="${CONTROLLER_MOBILE_HOST:-0.0.0.0}"
CONTROLLER_SERVER_PORT="${CONTROLLER_MOBILE_PORT:-1111}"
export CONTROLLER_SERVER_HOST
export CONTROLLER_SERVER_PORT

"$APP_ROOT/linux-controller-build-web.sh"
exec "$APP_ROOT/linux-controller-server.sh"
