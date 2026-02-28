# Controller App (Flutter Linux)

Landscape touch controller for Linux Mint Cinnamon.

Tabs:

- `Main`: tiles (automation/device/Spotify/Weather)
- `Devices`: scan/add/manage devices
- `Config`: integrations, display settings, OTA key, backend URL, local login
  - includes MOES BHUB-W local discovery, Tuya local scan import, and Tuya cloud import actions

Main tile behavior:

- Device tile: quick relay toggle command
- Device tile shows source + mode (local/cloud) and warns before cloud control
- Spotify tile: now playing + previous/pause-play/next controls
- Weather tile: current weather summary
- Automation tile: trigger placeholder action

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

Default backend URL: `http://127.0.0.1:8088`

For split deployment (Windows flasher + Linux controller), set backend URL in Config:
- `http://<windows-flasher-ip>:8088`
