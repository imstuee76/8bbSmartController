# 8bb Smart Controller

Monorepo for a local-first home automation platform with two core parts:

1. `controller-app/` - Flutter Linux touch controller (landscape)
2. `flasher-web/` - FastAPI flasher + local management web/API
3. `esp32-firmware/` - ESP-IDF firmware for relay/light/fan devices

## Core requirements covered

- Persistent settings and data (`/data`) with append-only logs.
- Device passcode pairing model.
- LAN discovery flow (mDNS + subnet scan hooks).
- Flashing workflow for ESP32 firmware.
- Signed OTA package generation + OTA push path.
- Tabs in controller: Main, Devices, Config.
- Config includes Spotify, Weather, Tuya, and OTA signing credentials.

## Repository layout

- `controller-app/` Flutter app (Linux Mint Cinnamon touch, landscape-first)
- `flasher-web/` FastAPI backend for devices, config, scan, flash, OTA signing
- `esp32-firmware/` ESP-IDF firmware runtime
- `shared/` shared schema/docs
- `data/` runtime state, logs, generated artifacts; never auto-deleted by app
  - includes `flasher.db`, `logs/events.jsonl`, firmware binaries, OTA manifests, firmware profile folders

## Quick start (separated, no venv)

Run flasher backend only (Windows machine):

```bash
run.cmd
# or
python run.py --mode backend
# mobile/LAN preset (host 0.0.0.0, port 1111)
run-mobile.cmd
```

Useful options:

```bash
python run.py --mode backend

# controller only
python run.py --mode controller

# controller on a specific Flutter device target
python run.py --mode controller --device linux

# skip install/update step for selected mode
python run.py --skip-install
```

Windows with `run.cmd`:

```bash
run.cmd --mode backend
run.cmd --mode controller --device linux
```

The launcher auto-installs required dependencies for the selected mode:
- backend via `python -m uvicorn ...`
- controller via `flutter run`

## Versioning

- Shared version manifest: `shared/version.json`
- Controller version label is shown in the top app bar (front screen).
- Flasher version label is shown at top of web UI.

Auto-bump both controller and flasher versions:

```bash
python scripts/bump_versions.py
```

This updates:
- `shared/version.json`
- `controller-app/pubspec.yaml`
- `controller-app/lib/app_version.dart`

## Git push using `.env`

Set token/repo in `.env` (or `data/.env`) and run:

```bash
python git_push.py
# Windows
git_push.cmd
```

Notes:
- Uses token from `.env` without writing token to git remote URL.
- `GITHUB_REPO` supports either `owner/repo` or owner-only with `GITHUB_REPO_NAME`.
- Initializes git repo if missing.
- Bumps versions automatically before commit unless `--skip-bump` is used.
- Git logs are written to `data/logs/git/sessions/`.

## Linux controller updater + runner

Copy project to Linux controller path:

`/home/arcade/8bbController`

Create credentials file:

`/home/arcade/8bbController/data/.env`

Run updater:

```bash
cd /home/arcade/8bbController
chmod +x linux-controller-updater.sh linux-controller-run.sh
./linux-controller-updater.sh
```

Run controller app:

```bash
./linux-controller-run.sh
```

Behavior:
- Never deletes `/data`.
- Loads `.env` from `/data/.env` first.
- Does not require `.git`; downloads latest GitHub archive and syncs controller runtime files.
- Overwrites controller app files each update, but preserves `.env` and `/data` storage.
- Syncs both controller and local server runtime (`flasher-web`) files.
- Installs missing controller deps, local backend Python deps, and local Flutter SDK bootstrap to `.tools/flutter` if Flutter is not in PATH.
- `linux-controller-run.sh` auto-starts local backend (`flasher-web`) by default, then starts controller.
- If backend is not running, app launch auto-starts it; backend stays running after app closes.
- Auto-creates missing Flutter Linux desktop scaffolding (`controller-app/linux`) when needed.
- Writes updater logs to `/data/logs/updater/sessions/<session>/`.
- Writes controller run logs to `/data/logs/controller/sessions/<session>/`.
- Local backend logs are also written in each controller session folder (`backend-*.log`, `backend-errors-*.log`).
- Updater creates desktop shortcuts for app launch, updater, and server stop control.
- Updater also creates `8bb Flasher Web` shortcut.
- Updater also creates `8bb Flasher Stop` shortcut.
- `linux-flasher-web.sh` works like a one-shot launcher: it opens existing backend if running, otherwise starts a temporary backend in that terminal and opens browser. Closing that terminal stops the temporary backend.
- Updater auto-adds a UFW firewall allow rule for `CONTROLLER_SERVER_PORT` (default `1111`) when UFW is active.
- Updater also configures Linux serial access (dialout/tty groups + udev rule for `ttyUSB*`/`ttyACM*`) for ESP flashing.

## Split deployment model

- Recommended default: Linux controller runs both `controller-app` and local `flasher-web` backend (standalone mode).
- Optional: disable local backend and use remote Windows backend by setting:
  - `CONTROLLER_USE_LOCAL_BACKEND=0`
  - `CONTROLLER_BACKEND_URL=http://<windows-ip>:1111`
- Windows flasher can still be used as a separate machine for occasional serial flashing workflows.

## Mobile controller (Chrome/Android install)

Linux one-command mobile host (builds Flutter web + serves API/UI on LAN `:1111`):

```bash
chmod +x linux-controller-mobile.sh
./linux-controller-mobile.sh
```

Always-on Linux service (auto-start on boot):

```bash
chmod +x linux-controller-build-web.sh linux-controller-server.sh linux-controller-install-service.sh
sudo ./linux-controller-install-service.sh
```

Service controls:

```bash
sudo systemctl status 8bb-controller-server.service
sudo systemctl restart 8bb-controller-server.service
sudo systemctl stop 8bb-controller-server.service
```

Unified server control helper (service or manual):

```bash
./linux-controller-server-control.sh status
./linux-controller-server-control.sh stop
./linux-controller-server-control.sh start
./linux-controller-server-control.sh logs 120
```

Windows one-command backend host on LAN `:1111`:

```bash
run-mobile.cmd
```

Phone URL:

`http://<machine-ip>:1111/controller/`

Install from Chrome using **Add to Home Screen**.

## Legacy manual start

### Flasher backend

```bash
# from repo root
python -m pip install --user --upgrade -r requirements.txt
python -m uvicorn app.main:app --app-dir flasher-web --host 0.0.0.0 --port 1111 --reload
```

Web UI: `http://localhost:1111/`

### Docker backend

```bash
docker compose up --build flasher-web
```

### Controller app (Flutter Linux)

```bash
cd controller-app
flutter pub get
flutter run -d linux
```

## BLE tester GUI (standalone)

Use this to test direct Bluetooth light controllers from the server machine:

```bash
python RGBLightBluetoothscanner.py
```

If needed, install BLE dependency first:

```bash
python -m pip install --user bleak
```

Features:
- BLE scan
- connect/disconnect
- services/characteristics capability list
- read/write characteristic values
- notification subscribe/unsubscribe
- per-session structured logs under `data/logs/ble-scanner/sessions/`
  - `activity-YYYYMMDD.jsonl`
  - `errors-YYYYMMDD.jsonl`
  - `artifacts/ble_devices_latest.json`
  - `artifacts/ble_characteristics_latest.json`

### ESP-IDF firmware

```bash
cd esp32-firmware
idf.py set-target esp32
idf.py build
```

## Notes

- Data persistence defaults to `../data` from each component (configurable via env vars).
- Tuya fallback files supported in `/data`:
  - `.app_keys` (or `.pp_keys`, `app_keys.json`) for cloud credentials fallback
  - `devices.json` for known Tuya device/local-key enrichment during scans
- OTA signing uses HMAC-SHA256 signature manifests under `data/ota`.
- For production use, add HTTPS/TLS and controller authentication.
