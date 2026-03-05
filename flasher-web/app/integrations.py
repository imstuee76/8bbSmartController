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


def _get_spotify_access_token(spotify_cfg: dict[str, Any], timeout_s: float = 15.0) -> str:
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
    with httpx.Client(timeout=timeout_s) as client:
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


def spotify_now_playing(timeout_s: float = 15.0) -> dict[str, Any]:
    spotify_cfg = get_setting("spotify")
    token = _get_spotify_access_token(spotify_cfg, timeout_s=timeout_s)
    headers = {"Authorization": f"Bearer {token}"}

    with httpx.Client(timeout=timeout_s) as client:
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


def weather_current(timeout_s: float = 15.0) -> dict[str, Any]:
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
    with httpx.Client(timeout=timeout_s) as client:
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


def _tuya_effective_cfg(
    *,
    cloud_region: str = "",
    client_id: str = "",
    client_secret: str = "",
    api_device_id: str = "",
) -> dict[str, Any]:
    tuya_cfg = get_setting("tuya")
    resolved_secret = client_secret.strip() if client_secret.strip() else decrypt_secret(tuya_cfg.get("client_secret", "")).strip()
    return {
        "cloud_region": cloud_region.strip() or str(tuya_cfg.get("cloud_region", "")).strip(),
        "client_id": client_id.strip() or str(tuya_cfg.get("client_id", "")).strip(),
        "client_secret": resolved_secret,
        "api_device_id": api_device_id.strip() or str(tuya_cfg.get("api_device_id", "")).strip(),
        "default_local_key": decrypt_secret(tuya_cfg.get("local_key", "")).strip(),
        "local_scan_enabled": bool(tuya_cfg.get("local_scan_enabled", True)),
    }


def _tuya_cloud_device_list(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    region = str(cfg.get("cloud_region", "")).strip()
    client_id = str(cfg.get("client_id", "")).strip()
    client_secret = str(cfg.get("client_secret", "")).strip()
    api_device_id = str(cfg.get("api_device_id", "")).strip()

    if not region or not client_id or not client_secret:
        raise ValueError("Tuya cloud credentials missing (region, client_id, client_secret)")

    try:
        import tinytuya  # type: ignore
    except Exception as exc:  # pragma: no cover - optional import
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    cloud = tinytuya.Cloud(  # type: ignore[attr-defined]
        apiRegion=region,
        apiKey=client_id,
        apiSecret=client_secret,
        apiDeviceID=api_device_id,
    )
    res = cloud.getdevices()
    if not isinstance(res, dict):
        raise ValueError("Unexpected Tuya cloud response")
    if not res.get("success", False):
        raise ValueError(f"Tuya cloud query failed: {res}")

    raw_items = res.get("result", [])
    if not isinstance(raw_items, list):
        return []

    normalized: list[dict[str, Any]] = []
    for raw in raw_items:
        if not isinstance(raw, dict):
            continue
        item = dict(raw)
        item["id"] = str(raw.get("id", raw.get("dev_id", ""))).strip()
        item["name"] = str(raw.get("name", "")).strip()
        item["ip"] = str(raw.get("ip", raw.get("local_ip", ""))).strip()
        item["mac"] = str(raw.get("mac", "")).strip().lower()
        item["category"] = str(raw.get("category", "")).strip()
        item["product_name"] = str(raw.get("product_name", raw.get("productName", ""))).strip()
        item["version"] = str(raw.get("version", "")).strip()
        item["local_key"] = str(raw.get("local_key", raw.get("key", ""))).strip()
        item["online"] = raw.get("online")
        normalized.append(item)
    return normalized


def _tuya_cloud_indexes(cloud_devices: list[dict[str, Any]]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    by_id: dict[str, dict[str, Any]] = {}
    by_mac: dict[str, dict[str, Any]] = {}
    by_ip: dict[str, dict[str, Any]] = {}
    for item in cloud_devices:
        dev_id = str(item.get("id", "")).strip()
        mac = str(item.get("mac", "")).strip().lower()
        ip = str(item.get("ip", "")).strip()
        if dev_id and dev_id not in by_id:
            by_id[dev_id] = item
        if mac and mac not in by_mac:
            by_mac[mac] = item
        if ip and ip not in by_ip:
            by_ip[ip] = item
    return by_id, by_mac, by_ip


def tuya_local_scan(
    subnet_hint: str = "",
    *,
    cloud_region: str = "",
    client_id: str = "",
    client_secret: str = "",
    api_device_id: str = "",
) -> dict[str, Any]:
    cfg = _tuya_effective_cfg(
        cloud_region=cloud_region,
        client_id=client_id,
        client_secret=client_secret,
        api_device_id=api_device_id,
    )
    if not cfg.get("local_scan_enabled", True):
        return {"devices": [], "enabled": False}

    hint = (subnet_hint or "").strip()
    primed = 0
    if hint:
        primed = prime_neighbors(hint)

    try:
        import tinytuya  # type: ignore
    except Exception as exc:  # pragma: no cover - optional import
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    devices = tinytuya.deviceScan(maxretry=6)  # type: ignore[attr-defined]
    out: list[dict[str, Any]] = []
    for _, details in (devices or {}).items():
        item = details if isinstance(details, dict) else {}
        out.append(
            {
                "id": str(item.get("gwId", "")).strip(),
                "ip": str(item.get("ip", "")).strip(),
                "mac": str(item.get("mac", "")).strip().lower(),
                "version": str(item.get("version", "")).strip(),
                "product_key": str(item.get("productKey", "")).strip(),
                "name": str(item.get("name", "")).strip(),
                "source": "lan_scan",
            }
        )

    cloud_devices: list[dict[str, Any]] = []
    cloud_error = ""
    cloud_enriched = False
    cloud_cfg_present = bool(cfg.get("cloud_region") and cfg.get("client_id") and cfg.get("client_secret"))
    if cloud_cfg_present:
        try:
            cloud_devices = _tuya_cloud_device_list(cfg)
            cloud_enriched = True
        except Exception as exc:
            cloud_error = str(exc)

    if out and cloud_devices:
        by_id, by_mac, by_ip = _tuya_cloud_indexes(cloud_devices)
        for item in out:
            dev_id = str(item.get("id", "")).strip()
            mac = str(item.get("mac", "")).strip().lower()
            ip = str(item.get("ip", "")).strip()
            match = by_id.get(dev_id) if dev_id else None
            if match is None and mac:
                match = by_mac.get(mac)
            if match is None and ip:
                match = by_ip.get(ip)
            if match is None:
                continue
            if not item.get("id"):
                item["id"] = str(match.get("id", "")).strip()
            if not item.get("name"):
                item["name"] = str(match.get("name", "")).strip()
            if not item.get("version"):
                item["version"] = str(match.get("version", "")).strip()
            if not item.get("mac"):
                item["mac"] = str(match.get("mac", "")).strip().lower()
            item["category"] = str(match.get("category", "")).strip()
            item["product_name"] = str(match.get("product_name", "")).strip()
            item["online"] = match.get("online")
            local_key = str(match.get("local_key", "")).strip()
            if local_key:
                item["local_key"] = local_key
                item["local_key_source"] = "tuya_cloud"
                item["available_modes"] = ["local_lan", "cloud"]

    default_local_key = str(cfg.get("default_local_key", "")).strip()
    if default_local_key:
        for item in out:
            if str(item.get("local_key", "")).strip():
                continue
            item["local_key"] = default_local_key
            item["local_key_source"] = "tuya_default"
            item["available_modes"] = ["local_lan", "cloud"] if cloud_cfg_present else ["local_lan"]

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
            "cloud_enriched": cloud_enriched,
            "cloud_error": cloud_error,
            "cloud_cfg_present": cloud_cfg_present,
        },
    )
    return {
        "devices": out,
        "enabled": True,
        "subnet_hint": hint,
        "primed_hosts": primed,
        "lan_candidates": lan_candidates[:40],
        "cloud_enriched": cloud_enriched,
        "cloud_error": cloud_error,
    }


def tuya_cloud_devices(
    *,
    cloud_region: str = "",
    client_id: str = "",
    client_secret: str = "",
    api_device_id: str = "",
) -> dict[str, Any]:
    cfg = _tuya_effective_cfg(
        cloud_region=cloud_region,
        client_id=client_id,
        client_secret=client_secret,
        api_device_id=api_device_id,
    )
    devices = _tuya_cloud_device_list(cfg)
    result = {
        "devices": devices,
        "cloud_region": str(cfg.get("cloud_region", "")).strip(),
        "api_device_id": str(cfg.get("api_device_id", "")).strip(),
    }
    append_event("tuya_cloud_query", {"count": len(devices), "cloud_region": result["cloud_region"]})
    return result
