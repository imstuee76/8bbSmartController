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
- Does not require `.git`; downloads latest GitHub archive and syncs controller-only files.
- Overwrites controller app files each update, but preserves `.env` and `/data` storage.
- Installs missing controller deps, including local Flutter SDK bootstrap to `.tools/flutter` if Flutter is not in PATH.
- `linux-controller-run.sh` auto-runs updater once when Flutter is missing, then starts controller.
- Auto-creates missing Flutter Linux desktop scaffolding (`controller-app/linux`) when needed.
- Writes updater logs to `/data/logs/updater/sessions/<session>/`.
- Writes controller run logs to `/data/logs/controller/sessions/<session>/`.

## Split deployment model

- `flasher-web` runs on Windows PC/server.
- `controller-app` runs on Linux Mint touch controller.
- They are separate processes/machines; only LAN API communication is shared.
- In controller `Config`, set backend URL to your Windows flasher IP:
  - example: `http://192.168.1.50:8088`

## Legacy manual start

### Flasher backend

```bash
# from repo root
python -m pip install --user --upgrade -r requirements.txt
python -m uvicorn app.main:app --app-dir flasher-web --host 0.0.0.0 --port 8088 --reload
```

Web UI: `http://localhost:8088/`

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

### ESP-IDF firmware

```bash
cd esp32-firmware
idf.py set-target esp32
idf.py build
```

## Notes

- Data persistence defaults to `../data` from each component (configurable via env vars).
- OTA signing uses HMAC-SHA256 signature manifests under `data/ota`.
- For production use, add HTTPS/TLS and controller authentication.
