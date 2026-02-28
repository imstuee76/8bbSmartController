from __future__ import annotations

from typing import Any

import httpx


def normalize_device_host(host: str) -> str:
    value = host.strip()
    if value.startswith("http://") or value.startswith("https://"):
        return value.rstrip("/")
    return f"http://{value.rstrip('/')}"


def fetch_device_status(host: str) -> dict[str, Any]:
    base = normalize_device_host(host)
    with httpx.Client(timeout=8) as client:
        res = client.get(f"{base}/api/status")
    res.raise_for_status()
    return res.json()


def send_device_command(host: str, passcode: str, command: dict[str, Any]) -> dict[str, Any]:
    base = normalize_device_host(host)
    payload = dict(command)
    payload["passcode"] = passcode
    with httpx.Client(timeout=8) as client:
        res = client.post(f"{base}/api/control", json=payload)
    res.raise_for_status()
    body = res.text.strip()
    if not body:
        return {"ok": True}
    try:
        return res.json()
    except Exception:
        return {"ok": True, "raw": body}


def push_ota_to_device(
    host: str,
    passcode: str,
    firmware_url: str,
    manifest_url: str,
) -> dict[str, Any]:
    base = normalize_device_host(host)
    payload = {
        "passcode": passcode,
        "firmware_url": firmware_url,
        "manifest_url": manifest_url,
    }
    with httpx.Client(timeout=20) as client:
        res = client.post(f"{base}/api/ota/apply", json=payload)
    res.raise_for_status()
    try:
        return res.json()
    except Exception:
        return {"ok": True, "raw": res.text}
