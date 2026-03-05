from __future__ import annotations

import os
import time
from typing import Any
from collections.abc import Callable

import httpx


def normalize_device_host(host: str) -> str:
    value = host.strip()
    if value.startswith("http://") or value.startswith("https://"):
        return value.rstrip("/")
    return f"http://{value.rstrip('/')}"


def fetch_device_status(host: str, timeout: float = 8.0) -> dict[str, Any]:
    base = normalize_device_host(host)
    with httpx.Client(timeout=timeout) as client:
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
    progress_cb: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    def progress(message: str) -> None:
        if progress_cb:
            try:
                progress_cb(str(message))
            except Exception:
                # Logging callback must never break OTA call path.
                pass

    timeout_s = float(os.environ.get("OTA_PUSH_HTTP_TIMEOUT_SECONDS", "180"))
    base = normalize_device_host(host)
    endpoint = f"{base}/api/ota/apply"
    payload = {
        "passcode": passcode,
        "firmware_url": firmware_url,
        "manifest_url": manifest_url,
    }
    progress(f"HTTP POST {endpoint}")
    progress(f"firmware_url={firmware_url}")
    progress(f"manifest_url={manifest_url}")
    timeout = httpx.Timeout(connect=10.0, read=timeout_s, write=20.0, pool=20.0)
    started = time.perf_counter()
    with httpx.Client(timeout=timeout) as client:
        res = client.post(endpoint, json=payload)
    elapsed_ms = int((time.perf_counter() - started) * 1000)
    progress(f"HTTP {res.status_code} in {elapsed_ms}ms")
    body_text = (res.text or "").strip()
    if body_text:
        preview = body_text if len(body_text) <= 900 else f"{body_text[:900]}...<truncated>"
        progress(f"response_body={preview}")
    try:
        res.raise_for_status()
    except httpx.HTTPStatusError as exc:
        detail = body_text[:500] if body_text else "no response body"
        raise httpx.HTTPStatusError(
            f"Device OTA endpoint rejected request: HTTP {res.status_code}; body={detail}",
            request=exc.request,
            response=exc.response,
        ) from exc
    try:
        parsed = res.json()
    except Exception:
        parsed = {"ok": True, "raw": body_text}
    if isinstance(parsed, dict):
        parsed.setdefault("_http_status", res.status_code)
        parsed.setdefault("_http_elapsed_ms", elapsed_ms)
    return parsed
