from __future__ import annotations

import time
from typing import Any

import httpx

from .security import decrypt_secret
from .scanner import prime_neighbors, scan_network
from .storage import append_event, get_setting

_spotify_cache: dict[str, Any] = {
    "access_token": "",
    "expires_at": 0.0,
}


def _get_spotify_access_token(spotify_cfg: dict[str, Any]) -> str:
    now = time.time()
    cached = _spotify_cache.get("access_token", "")
    if cached and float(_spotify_cache.get("expires_at", 0.0)) > (now + 30):
        return cached

    refresh_token = spotify_cfg.get("refresh_token", "")
    client_id = spotify_cfg.get("client_id", "")
    client_secret = decrypt_secret(spotify_cfg.get("client_secret", ""))
    if not refresh_token or not client_id or not client_secret:
        raise ValueError("Spotify credentials missing (client_id/client_secret/refresh_token)")

    data = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
        "client_secret": client_secret,
    }
    with httpx.Client(timeout=15) as client:
        res = client.post("https://accounts.spotify.com/api/token", data=data)
        res.raise_for_status()
        body = res.json()

    token = body.get("access_token", "")
    expires_in = int(body.get("expires_in", 3600))
    if not token:
        raise ValueError("Spotify token response missing access_token")
    _spotify_cache["access_token"] = token
    _spotify_cache["expires_at"] = now + expires_in
    return token


def spotify_now_playing() -> dict[str, Any]:
    spotify_cfg = get_setting("spotify")
    token = _get_spotify_access_token(spotify_cfg)
    headers = {"Authorization": f"Bearer {token}"}

    with httpx.Client(timeout=15) as client:
        res = client.get("https://api.spotify.com/v1/me/player/currently-playing", headers=headers)
    if res.status_code == 204:
        return {"is_playing": False, "track": None}
    if res.status_code >= 400:
        raise ValueError(f"Spotify currently-playing failed: {res.text}")

    body = res.json()
    item = body.get("item") or {}
    artists = ", ".join(a.get("name", "") for a in item.get("artists", []))
    out = {
        "is_playing": bool(body.get("is_playing")),
        "progress_ms": body.get("progress_ms"),
        "track": {
            "name": item.get("name"),
            "album": (item.get("album") or {}).get("name"),
            "artists": artists,
            "duration_ms": item.get("duration_ms"),
        }
        if item
        else None,
    }
    return out


def spotify_action(action: str) -> dict[str, Any]:
    spotify_cfg = get_setting("spotify")
    token = _get_spotify_access_token(spotify_cfg)
    headers = {"Authorization": f"Bearer {token}"}
    base = "https://api.spotify.com/v1/me/player"
    action = action.lower().strip()
    device_id = spotify_cfg.get("device_id", "").strip()
    suffix = f"?device_id={device_id}" if device_id else ""

    endpoint_map = {
        "play": ("PUT", f"{base}/play{suffix}"),
        "pause": ("PUT", f"{base}/pause{suffix}"),
        "next": ("POST", f"{base}/next{suffix}"),
        "previous": ("POST", f"{base}/previous{suffix}"),
    }
    if action not in endpoint_map:
        raise ValueError(f"Unsupported Spotify action: {action}")

    method, url = endpoint_map[action]
    with httpx.Client(timeout=15) as client:
        res = client.request(method, url, headers=headers)
    if res.status_code >= 400:
        raise ValueError(f"Spotify action failed: {res.text}")

    append_event("spotify_action", {"action": action})
    return {"ok": True, "action": action}


def weather_current() -> dict[str, Any]:
    weather_cfg = get_setting("weather")
    provider = weather_cfg.get("provider", "openweather").strip().lower()
    api_key = decrypt_secret(weather_cfg.get("api_key", ""))
    location = weather_cfg.get("location", "").strip()
    units = weather_cfg.get("units", "metric")

    if provider != "openweather":
        raise ValueError("Only openweather provider is implemented in this release")
    if not api_key or not location:
        raise ValueError("Weather config missing api_key or location")

    params = {
        "q": location,
        "appid": api_key,
        "units": units,
    }
    with httpx.Client(timeout=15) as client:
        res = client.get("https://api.openweathermap.org/data/2.5/weather", params=params)
    if res.status_code >= 400:
        raise ValueError(f"Weather request failed: {res.text}")
    body = res.json()
    weather = (body.get("weather") or [{}])[0]
    main = body.get("main") or {}
    wind = body.get("wind") or {}

    return {
        "location": body.get("name"),
        "description": weather.get("description"),
        "icon": weather.get("icon"),
        "temp": main.get("temp"),
        "feels_like": main.get("feels_like"),
        "humidity": main.get("humidity"),
        "wind_speed": wind.get("speed"),
        "units": units,
    }


def tuya_local_scan(subnet_hint: str = "") -> dict[str, Any]:
    tuya_cfg = get_setting("tuya")
    if not tuya_cfg.get("local_scan_enabled", True):
        return {"devices": [], "enabled": False}

    hint = (subnet_hint or "").strip()
    primed = 0
    if hint:
        primed = prime_neighbors(hint)

    try:
        import tinytuya  # type: ignore
    except Exception as exc:  # pragma: no cover - optional import
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    devices = tinytuya.deviceScan(maxretry=12)  # type: ignore[attr-defined]
    out = []
    for _, details in (devices or {}).items():
        item = details if isinstance(details, dict) else {}
        out.append(
            {
                "id": item.get("gwId", ""),
                "ip": item.get("ip", ""),
                "mac": item.get("mac", ""),
                "version": item.get("version", ""),
                "product_key": item.get("productKey", ""),
                "name": item.get("name", ""),
            }
        )
    lan_candidates: list[dict[str, Any]] = []
    if hint:
        try:
            lan_scan = scan_network(hint, automation_only=True)
            lan_candidates = [
                {
                    "ip": str(item.get("ip", "")).strip(),
                    "hint": str(item.get("device_hint", "") or item.get("provider_hint", "")).strip(),
                    "score": int(item.get("score", 0)),
                }
                for item in lan_scan
                if str(item.get("ip", "")).strip()
            ]
        except Exception:
            lan_candidates = []

    append_event(
        "tuya_local_scan",
        {
            "count": len(out),
            "subnet_hint": hint,
            "primed_hosts": primed,
            "lan_candidates": len(lan_candidates),
        },
    )
    return {
        "devices": out,
        "enabled": True,
        "subnet_hint": hint,
        "primed_hosts": primed,
        "lan_candidates": lan_candidates[:40],
    }


def tuya_cloud_devices() -> dict[str, Any]:
    tuya_cfg = get_setting("tuya")
    region = tuya_cfg.get("cloud_region", "").strip()
    client_id = tuya_cfg.get("client_id", "").strip()
    client_secret = decrypt_secret(tuya_cfg.get("client_secret", ""))

    if not region or not client_id or not client_secret:
        raise ValueError("Tuya cloud credentials missing")

    try:
        import tinytuya  # type: ignore
    except Exception as exc:  # pragma: no cover - optional import
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    cloud = tinytuya.Cloud(  # type: ignore[attr-defined]
        apiRegion=region,
        apiKey=client_id,
        apiSecret=client_secret,
        apiDeviceID="",
    )
    res = cloud.getdevices()
    if not isinstance(res, dict):
        raise ValueError("Unexpected Tuya cloud response")
    if not res.get("success", False):
        raise ValueError(f"Tuya cloud query failed: {res}")
    result = {"devices": res.get("result", [])}
    append_event("tuya_cloud_query", {"count": len(result['devices'])})
    return result
