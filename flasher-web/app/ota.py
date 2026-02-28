from __future__ import annotations

import hashlib
import hmac
import json
from pathlib import Path
from typing import Any

from .storage import DATA_DIR, append_event, utc_now

OTA_DIR = DATA_DIR / "ota"


def _make_signature(shared_key: str, digest: str, version: str, device_type: str) -> str:
    message = f"{digest}:{version}:{device_type}".encode("utf-8")
    return hmac.new(shared_key.encode("utf-8"), message, hashlib.sha256).hexdigest()


def sign_firmware(firmware_path: Path, version: str, device_type: str, shared_key: str) -> dict[str, Any]:
    if not firmware_path.exists():
        raise FileNotFoundError(f"Firmware not found: {firmware_path}")
    if firmware_path.is_dir():
        raise ValueError(f"Firmware path points to a directory, not a file: {firmware_path}")
    if firmware_path.suffix.lower() != ".bin":
        raise ValueError(f"Firmware must be a .bin file: {firmware_path.name}")
    if not shared_key:
        raise ValueError("OTA shared key is empty")

    OTA_DIR.mkdir(parents=True, exist_ok=True)
    try:
        firmware_bytes = firmware_path.read_bytes()
    except PermissionError as exc:
        raise ValueError(f"Firmware file is not readable: {firmware_path}") from exc
    except OSError as exc:
        raise ValueError(f"Unable to read firmware file: {firmware_path}") from exc
    digest = hashlib.sha256(firmware_bytes).hexdigest()
    signature = _make_signature(shared_key, digest, version, device_type)

    manifest = {
        "created_at": utc_now(),
        "algorithm": "hmac-sha256",
        "firmware": firmware_path.name,
        "device_type": device_type,
        "version": version,
        "sha256": digest,
        "signature": signature,
    }

    manifest_path = OTA_DIR / f"{firmware_path.stem}-{version}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    append_event("ota_signed", {"manifest": str(manifest_path), "firmware": firmware_path.name, "version": version})

    return {
        "manifest": manifest,
        "manifest_path": str(manifest_path),
    }


def verify_manifest(manifest: dict[str, Any], shared_key: str) -> bool:
    if manifest.get("algorithm") != "hmac-sha256":
        return False
    digest = str(manifest.get("sha256", ""))
    version = str(manifest.get("version", ""))
    device_type = str(manifest.get("device_type", ""))
    signature = str(manifest.get("signature", ""))
    expected = _make_signature(shared_key, digest, version, device_type)
    return hmac.compare_digest(expected, signature)
