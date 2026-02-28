# Flasher Web

FastAPI backend + local web UI for:

- Device registry
- Network discovery scan
- Firmware upload (`.bin`)
- ESP32 flash jobs (`esptool`)
- Signed OTA manifest generation
- OTA push to registered devices over LAN
- Firmware profile save/recall (dated folder with metadata + firmware + manifest)
- Credentials/config persistence
- Local admin login
- Spotify/Weather/Tuya integration endpoints
- MOES BHUB-W local LAN discovery + local child-light control (no cloud required)
- Tuya local LAN and Tuya cloud device command/status support (single device list + tiles)

## Web workflow

The flasher UI is profile-first and split into clear steps:

1. New profile: name, version, firmware, notes, and device type.
2. Device options: common options + dynamic options by type (relay, fan, single light, dimmer, RGB, RGBW).
3. Network setup: Wi-Fi, fallback AP, and DHCP/static IP fields.
4. Actions:
   - Build firmware from source (ESP-IDF project in `../esp32-firmware`)
   - Flash to serial port (live flash output)
   - Live serial monitor (start/stop, selected COM port + baud)
   - Build OTA file (creates a profile package folder)
   - Flash OTA (push selected saved profile to selected registered device)

Draft form values are auto-saved in browser storage so incomplete setup work is not lost if the page is refreshed.

## Run

```bash
cd ..
python run.py --mode backend
# Windows shortcut:
run.cmd --mode backend
```

Or manual (no venv):

```bash
python -m pip install --user --upgrade -r requirements.txt
python -m uvicorn app.main:app --host 0.0.0.0 --port 8088 --reload
```

Open:

- Web UI: `http://localhost:8088/`
- API docs: `http://localhost:8088/docs`

## Data

All runtime state is stored under `../data` and not auto-deleted:

- `flasher.db` SQLite state
- `logs/events.jsonl` append-only event log
- `firmware/*.bin` flashable firmware
- `ota/*.manifest.json` signed OTA manifests
- `firmware_profiles/<dated_profile_folder>/` saved profile packages
  - `metadata.json` (settings, notes, dates, file references)
  - firmware `.bin`
  - OTA manifest `.manifest.json`
- `logs/firmware_builds/*.log` persistent ESP-IDF build logs (one file per build attempt)

## Integration endpoints

- `GET /api/integrations/spotify/now-playing`
- `POST /api/integrations/spotify/action`
- `GET /api/integrations/weather/current`
- `POST /api/integrations/tuya/local-scan`
- `POST /api/integrations/tuya/cloud-devices`
- `POST /api/integrations/moes/discover-local`
- `POST /api/integrations/moes/discover-lights` (local hub query via `hub_ip` + `hub_local_key` + `hub_version`)

## Firmware profile endpoints

- `POST /api/firmware/build` compile firmware from `esp32-firmware` and save `.bin` files under `data/firmware`
- `POST /api/firmware/profiles` create profile from selected firmware
- `GET /api/firmware/profiles` list saved profiles
- `GET /api/firmware/profiles/{profile_id}` recall full profile details
- `POST /api/firmware/profiles/{profile_id}/push/{device_id}` push selected saved profile OTA to a device

## Serial monitor endpoints

- `POST /api/serial/monitor/start` start live serial monitor session
- `GET /api/serial/monitor/{session_id}` get running status + buffered output
- `POST /api/serial/monitor/{session_id}/stop` stop monitor session

## Bring-up diagnostics endpoints

- `POST /api/diagnostics/extract-ip` parse IP candidates from serial monitor output
- `POST /api/diagnostics/ping` ping host/IP from backend machine
- `POST /api/diagnostics/status` check device `GET /api/status`
- `POST /api/diagnostics/pair` check device `POST /api/pair` with passcode
- `POST /api/diagnostics/run-all` run ping + status + pair checks

## ESP-IDF prerequisite

When using `POST /api/firmware/build` (or the **Build Firmware** button), backend must be started in an environment where `idf.py` is available in PATH.

If auto-detect does not find ESP-IDF, set one of these before starting backend:

- `IDF_CMD` (full command, example: `idf.py` or full path)
- or `IDF_PY_PATH` (path to `idf.py`) and optional `ESP_IDF_PYTHON` (path to ESP-IDF Python)

Windows option (recommended):

1. Install ESP-IDF Installation Manager CLI:
   - `winget install --id Espressif.EIM-CLI -e`
2. Install an ESP-IDF toolchain/version:
   - `eim install --non-interactive true --target esp32 --path C:\Espressif`
3. Verify:
   - `eim list`
