# Controller App (Flutter Linux + Mobile Web/Android)

Landscape touch controller for Linux Mint Cinnamon.

Tabs:

- `Main`: tiles (automation/device/Spotify/Weather)
- `Devices`: scan/add/manage devices
- `Config`: integrations, display settings, OTA key, backend URL, local login
  - includes MOES BHUB-W local discovery, Tuya local scan import, and Tuya cloud import actions
  - Tuya setup supports Access ID, Access Secret, API Device ID, and optional default local key

Main tile behavior:

- Device tile: quick relay toggle command
- Device tile shows source + mode (local/cloud) and warns before cloud control
- Spotify tile: now playing + previous/pause-play/next controls
- Weather tile: current weather summary
- Automation tile: trigger placeholder action

Tuya add flow:

- Scan Tuya local/cloud from Config.
- For each discovered Tuya device, choose add mode: `Local LAN` or `Cloud`.
- Local mode uses per-device local key from cloud enrichment when available (or prompts once if missing).

## Run

```bash
cd ..
python run.py --mode controller --device linux
```

Or manual:

```bash
flutter pub get
flutter run -d linux
```

Default backend URL: `http://127.0.0.1:1111`

For split deployment (Windows flasher + Linux controller), set backend URL in Config:
- `http://<windows-flasher-ip>:1111`

## Mobile (Chrome install app / Android)

Generate missing Flutter platform folders once:

```bash
flutter create --platforms=web,android .
```

Build web app for backend-hosted `/controller/` path:

```bash
flutter build web --release --base-href /controller/
```

Then run backend on LAN port `1111`:

```bash
cd ..
python run.py --mode backend --host 0.0.0.0 --port 1111
```

Open on phone:

`http://<machine-ip>:1111/controller/`

In Chrome, choose **Add to Home Screen** to install as an app.

For always-on Linux server mode, use repo script:

```bash
sudo ../linux-controller-install-service.sh
```
