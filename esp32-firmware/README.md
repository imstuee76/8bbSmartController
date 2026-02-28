# ESP32 Firmware (ESP-IDF)

This firmware runtime provides:

- LAN control API for relay/light/fan devices
- Device passcode gate on control/config endpoints
- Wi-Fi station with fallback AP mode
- Persistent config in NVS
- Signed OTA workflow with HMAC-SHA256 manifest verification on device

## API Endpoints

- `GET /api/status`
- `POST /api/pair` with `{"passcode":"..."}`
- `POST /api/config` (name, type, wifi/ap/static IP fields, ota_key, passcode)
- `POST /api/control` (channel/state/value + passcode)
- `POST /api/ota/apply` (firmware_url, manifest_url + passcode)

## Build

```bash
idf.py set-target esp32
idf.py build
```

## Flash

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```

## Signed OTA Notes

The flasher backend creates signed manifests under `../data/ota` using:

- `algorithm: hmac-sha256`
- message format: `<sha256>:<version>:<device_type>`

The device verifies manifest signature using its configured `ota_key` before downloading and applying firmware.
