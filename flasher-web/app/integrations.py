from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

import httpx

from .security import decrypt_secret
from .scanner import prime_neighbors, scan_network
from .storage import DATA_DIR, append_event, get_setting, utc_now

_spotify_cache: dict[str, Any] = {
    "access_token": "",
    "expires_at": 0.0,
}


def _tuya_devices_file_candidates() -> list[Path]:
    return [
        (DATA_DIR / "devices.json").resolve(),
        (DATA_DIR / "tuya_devices.json").resolve(),
    ]


def _parse_tuya_devices_file(path: Path) -> tuple[list[dict[str, Any]], str]:
    if not path.exists() or not path.is_file():
        return [], "missing"
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except Exception as exc:
        return [], f"read_error: {exc}"
    if not raw:
        return [], "empty"
    try:
        payload = json.loads(raw)
    except Exception as exc:
        return [], f"json_error: {exc}"

    rows: list[dict[str, Any]] = []
    if isinstance(payload, list):
        rows = [dict(item) for item in payload if isinstance(item, dict)]
    elif isinstance(payload, dict):
        if isinstance(payload.get("devices"), list):
            rows = [dict(item) for item in payload.get("devices", []) if isinstance(item, dict)]
        else:
            # Some exports are a dict keyed by device id.
            for key, value in payload.items():
                if isinstance(value, dict):
                    row = dict(value)
                    if "id" not in row:
                        row["id"] = str(key)
                    rows.append(row)
    if rows:
        return rows, "ok"
    return [], "parsed_but_no_rows"


def _tuya_devices_file_diagnostics() -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    for path in _tuya_devices_file_candidates():
        exists = path.exists() and path.is_file()
        size_bytes = 0
        if exists:
            try:
                size_bytes = path.stat().st_size
            except Exception:
                size_bytes = 0
        parsed_rows, parse_state = _parse_tuya_devices_file(path)
        files.append(
            {
                "path": str(path),
                "exists": bool(exists),
                "size_bytes": int(size_bytes),
                "parse_state": parse_state,
                "parsed_rows": len(parsed_rows),
            }
        )
    return {
        "data_dir": str(DATA_DIR.resolve()),
        "files": files,
    }


def _load_tuya_devices_file() -> tuple[list[dict[str, Any]], str]:
    for path in _tuya_devices_file_candidates():
        rows, state = _parse_tuya_devices_file(path)
        if state == "ok" and rows:
            return rows, path.name
    return [], ""


def _tuya_devices_file_path() -> Path:
    return (DATA_DIR / "devices.json").resolve()


def _write_tuya_devices_file(payload: dict[str, Any]) -> str:
    path = _tuya_devices_file_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path.name


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

    cloud_region_final = cloud_region.strip() or str(tuya_cfg.get("cloud_region", "")).strip()
    client_id_final = client_id.strip() or str(tuya_cfg.get("client_id", "")).strip()
    api_device_id_final = api_device_id.strip() or str(tuya_cfg.get("api_device_id", "")).strip()
    return {
        "cloud_region": cloud_region_final,
        "client_id": client_id_final,
        "client_secret": resolved_secret,
        "api_device_id": api_device_id_final,
        "default_local_key": decrypt_secret(tuya_cfg.get("local_key", "")).strip(),
        "local_scan_enabled": bool(tuya_cfg.get("local_scan_enabled", True)),
        "app_keys_file": "",
    }


def _tuya_cloud_device_list(cfg: dict[str, Any]) -> list[dict[str, Any]]:
    region = str(cfg.get("cloud_region", "")).strip()
    client_id = str(cfg.get("client_id", "")).strip()
    client_secret = str(cfg.get("client_secret", "")).strip()
    api_device_id = str(cfg.get("api_device_id", "")).strip()

    if not region or not client_id or not client_secret or not api_device_id:
        raise ValueError("Tuya cloud credentials missing (region, client_id, client_secret, api_device_id)")

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
    raw_items: list[Any] = []
    if isinstance(res, list):
        raw_items = res
    elif isinstance(res, dict):
        if res.get("success") is False:
            detail = res.get("msg") or res.get("code") or res
            raise ValueError(f"Tuya cloud query failed: {detail}")
        result_obj = res.get("result")
        if isinstance(result_obj, list):
            raw_items = result_obj
        elif isinstance(result_obj, dict):
            if isinstance(result_obj.get("list"), list):
                raw_items = result_obj.get("list", [])
            elif all(isinstance(v, dict) for v in result_obj.values()):
                for key, value in result_obj.items():
                    row = dict(value)
                    if "id" not in row:
                        row["id"] = str(key)
                    raw_items.append(row)
        elif isinstance(res.get("devices"), list):
            raw_items = res.get("devices", [])
    else:
        preview = str(res)
        if len(preview) > 300:
            preview = preview[:300] + "..."
        raise ValueError(f"Unexpected Tuya cloud response type={type(res).__name__}: {preview}")

    if not isinstance(raw_items, list):
        raw_items = []

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


def _tuya_devices_file_indexes(file_devices: list[dict[str, Any]]) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    by_id: dict[str, dict[str, Any]] = {}
    by_mac: dict[str, dict[str, Any]] = {}
    by_ip: dict[str, dict[str, Any]] = {}
    for item in file_devices:
        dev_id = str(item.get("id") or item.get("gwId") or item.get("dev_id") or "").strip()
        mac = str(item.get("mac", "")).strip().lower()
        ip = str(item.get("ip", "")).strip()
        if dev_id and dev_id not in by_id:
            by_id[dev_id] = item
        if mac and mac not in by_mac:
            by_mac[mac] = item
        if ip and ip not in by_ip:
            by_ip[ip] = item
    return by_id, by_mac, by_ip


def _get_file_value(row: dict[str, Any], *names: str) -> str:
    for name in names:
        value = str(row.get(name, "")).strip()
        if value:
            return value
    return ""


def _tuya_identity(item: dict[str, Any]) -> str:
    dev_id = str(item.get("id", "")).strip()
    if dev_id:
        return f"id:{dev_id}"
    mac = str(item.get("mac", "")).strip().lower()
    if mac:
        return f"mac:{mac}"
    ip = str(item.get("ip", "")).strip()
    if ip:
        return f"ip:{ip}"
    return f"row:{hash(json.dumps(item, sort_keys=True, default=str))}"


def _normalize_tuya_row(item: dict[str, Any], *, source: str, mode: str) -> dict[str, Any]:
    local_key = str(item.get("local_key", "")).strip()
    provider = "tuya_local" if mode == "local_lan" else "tuya_cloud"
    available_modes = list(item.get("available_modes", [])) if isinstance(item.get("available_modes"), list) else []
    if not available_modes:
        available_modes = ["local_lan"] if mode == "local_lan" else ["cloud"]
    if local_key and "local_lan" not in available_modes:
        available_modes.append("local_lan")
    if "cloud" not in available_modes:
        available_modes.append("cloud")
    return {
        "id": str(item.get("id", "")).strip(),
        "name": str(item.get("name", "")).strip(),
        "ip": str(item.get("ip", "")).strip(),
        "mac": str(item.get("mac", "")).strip().lower(),
        "version": str(item.get("version", "")).strip(),
        "category": str(item.get("category", "")).strip(),
        "product_key": str(item.get("product_key", "")).strip(),
        "product_name": str(item.get("product_name", "")).strip(),
        "local_key": local_key,
        "online": item.get("online"),
        "source": source,
        "provider": provider,
        "mode": mode,
        "available_modes": available_modes,
    }


def _merge_tuya_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: dict[str, dict[str, Any]] = {}
    for row in rows:
        key = _tuya_identity(row)
        if key not in merged:
            merged[key] = dict(row)
            continue
        current = merged[key]
        for field, value in row.items():
            if field == "available_modes":
                prev = current.get(field, [])
                prev_list = prev if isinstance(prev, list) else []
                new_list = value if isinstance(value, list) else []
                current[field] = sorted({str(x) for x in [*prev_list, *new_list] if str(x).strip()})
                continue
            if (current.get(field) is None or str(current.get(field, "")).strip() == "") and str(value or "").strip():
                current[field] = value
        # Prefer local provider when local key is present.
        if str(current.get("local_key", "")).strip():
            current["provider"] = "tuya_local"
            current["mode"] = "local_lan"
    out = list(merged.values())
    out.sort(key=lambda item: (str(item.get("name", "")).lower(), str(item.get("id", "")).lower(), str(item.get("ip", ""))))
    return out


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

    file_devices, file_name = _load_tuya_devices_file()
    file_by_id, file_by_mac, file_by_ip = _tuya_devices_file_indexes(file_devices)

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

    # Enrich with existing devices.json export from /data for local keys and names.
    for item in out:
        dev_id = str(item.get("id", "")).strip()
        mac = str(item.get("mac", "")).strip().lower()
        ip = str(item.get("ip", "")).strip()
        match = file_by_id.get(dev_id) if dev_id else None
        if match is None and mac:
            match = file_by_mac.get(mac)
        if match is None and ip:
            match = file_by_ip.get(ip)
        if match is None:
            continue
        if not item.get("name"):
            item["name"] = _get_file_value(match, "name", "friendly_name")
        if not item.get("version"):
            item["version"] = _get_file_value(match, "version")
        local_key = _get_file_value(match, "local_key", "key")
        if local_key:
            item["local_key"] = local_key
            item["local_key_source"] = "devices_json"
            item["available_modes"] = ["local_lan", "cloud"] if bool(cfg.get("client_id")) else ["local_lan"]

    # If LAN scan found none, expose devices.json records with IP as fallback candidates.
    if not out and file_devices:
        for row in file_devices:
            ip = _get_file_value(row, "ip")
            if not ip:
                continue
            out.append(
                {
                    "id": _get_file_value(row, "id", "gwId", "dev_id"),
                    "ip": ip,
                    "mac": _get_file_value(row, "mac").lower(),
                    "version": _get_file_value(row, "version"),
                    "product_key": _get_file_value(row, "product_key", "productKey"),
                    "name": _get_file_value(row, "name", "friendly_name"),
                    "local_key": _get_file_value(row, "local_key", "key"),
                    "source": "devices_json_fallback",
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
            "app_keys_file": str(cfg.get("app_keys_file", "")),
            "devices_file": file_name,
            "devices_file_count": len(file_devices),
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
        "app_keys_file": str(cfg.get("app_keys_file", "")),
        "devices_file": file_name,
        "devices_file_count": len(file_devices),
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
        "app_keys_file": str(cfg.get("app_keys_file", "")),
    }
    append_event("tuya_cloud_query", {"count": len(devices), "cloud_region": result["cloud_region"]})
    return result


def tuya_test_credentials(
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
    cloud_region_final = str(cfg.get("cloud_region", "")).strip()
    client_id_final = str(cfg.get("client_id", "")).strip()
    client_secret_final = str(cfg.get("client_secret", "")).strip()
    api_device_id_final = str(cfg.get("api_device_id", "")).strip()
    cloud_configured = bool(cloud_region_final and client_id_final and client_secret_final and api_device_id_final)
    result: dict[str, Any] = {
        "ok": False,
        "cloud_configured": cloud_configured,
        "cloud_region": cloud_region_final,
        "api_device_id_present": bool(api_device_id_final),
        "client_id_present": bool(client_id_final),
        "client_secret_present": bool(client_secret_final),
        "local_key_present": bool(str(cfg.get("default_local_key", "")).strip()),
        "app_keys_file": str(cfg.get("app_keys_file", "")),
        "checked_at": utc_now(),
    }
    if not cloud_configured:
        result["error"] = "Tuya cloud test requires cloud_region, client_id, client_secret, and api_device_id."
        return result
    try:
        devices = _tuya_cloud_device_list(cfg)
        result["ok"] = True
        result["cloud_ok"] = True
        result["device_count"] = len(devices)
    except Exception as exc:
        result["ok"] = False
        result["cloud_ok"] = False
        result["error"] = str(exc)
    append_event("tuya_test_credentials", {"ok": bool(result.get("ok")), "cloud_configured": cloud_configured})
    return result


def tuya_scan_and_save(
    *,
    subnet_hint: str = "",
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
    local_result = tuya_local_scan(
        subnet_hint=subnet_hint,
        cloud_region=cloud_region,
        client_id=client_id,
        client_secret=client_secret,
        api_device_id=api_device_id,
    )
    local_devices = (local_result.get("devices", []) if isinstance(local_result.get("devices"), list) else [])
    normalized_local = [_normalize_tuya_row(dict(item), source="local_scan", mode="local_lan") for item in local_devices if isinstance(item, dict)]
    local_lan_scan_count = 0
    local_file_fallback_count = 0
    for item in local_devices:
        source = str(item.get("source", "")).strip().lower()
        if source == "lan_scan":
            local_lan_scan_count += 1
        elif source == "devices_json_fallback":
            local_file_fallback_count += 1

    cloud_devices: list[dict[str, Any]] = []
    cloud_error = ""
    cloud_cfg_complete = bool(
        str(cfg.get("cloud_region", "")).strip()
        and str(cfg.get("client_id", "")).strip()
        and str(cfg.get("client_secret", "")).strip()
        and str(cfg.get("api_device_id", "")).strip()
    )
    if cloud_cfg_complete:
        try:
            cloud_result = tuya_cloud_devices(
                cloud_region=cloud_region,
                client_id=client_id,
                client_secret=client_secret,
                api_device_id=api_device_id,
            )
            cloud_devices = cloud_result.get("devices", []) if isinstance(cloud_result.get("devices"), list) else []
        except Exception as exc:
            cloud_error = str(exc)
    normalized_cloud = [_normalize_tuya_row(dict(item), source="cloud_scan", mode="cloud") for item in cloud_devices if isinstance(item, dict)]

    existing_rows, existing_file_name = _load_tuya_devices_file()
    normalized_existing: list[dict[str, Any]] = []
    for row in existing_rows:
        mode = str(row.get("mode", "")).strip().lower()
        if mode not in ("local_lan", "cloud"):
            mode = "local_lan" if str(row.get("local_key", "")).strip() else "cloud"
        normalized_existing.append(_normalize_tuya_row(dict(row), source="devices_file", mode=mode))

    # Merge precedence: latest scan first, then existing devices.json for fallback/retention.
    # This prevents "scan produced 0" from wiping previously saved devices.
    merged = _merge_tuya_rows([*normalized_local, *normalized_cloud, *normalized_existing])

    scanned_identities = {_tuya_identity(row) for row in [*normalized_local, *normalized_cloud]}
    existing_only_count = 0
    for row in normalized_existing:
        identity = _tuya_identity(row)
        if identity not in scanned_identities:
            existing_only_count += 1
    devices_file_diag = _tuya_devices_file_diagnostics()
    cloud_cfg_presence = {
        "cloud_region": bool(str(cfg.get("cloud_region", "")).strip()),
        "client_id": bool(str(cfg.get("client_id", "")).strip()),
        "client_secret": bool(str(cfg.get("client_secret", "")).strip()),
        "api_device_id": bool(str(cfg.get("api_device_id", "")).strip()),
    }
    payload = {
        "updated_at": utc_now(),
        "subnet_hint": (subnet_hint or "").strip(),
        "devices": merged,
        "local_count": len(normalized_local),
        "cloud_count": len(normalized_cloud),
        "cloud_error": cloud_error,
        "app_keys_file": str(cfg.get("app_keys_file", "")),
        "existing_file_name": existing_file_name,
        "existing_file_count": len(normalized_existing),
        "existing_only_count": existing_only_count,
        "devices_file_diagnostics": devices_file_diag,
        "cloud_cfg_presence": cloud_cfg_presence,
    }
    file_name = _write_tuya_devices_file(payload)
    append_event(
        "tuya_scan_saved",
        {
            "devices": len(merged),
            "local_count": len(normalized_local),
            "cloud_count": len(normalized_cloud),
            "cloud_error": cloud_error,
            "file": file_name,
            "existing_file": existing_file_name,
            "existing_file_count": len(normalized_existing),
            "existing_only_count": existing_only_count,
            "local_lan_scan_count": local_lan_scan_count,
            "local_file_fallback_count": local_file_fallback_count,
            "devices_file_diagnostics": devices_file_diag,
            "cloud_cfg_presence": cloud_cfg_presence,
        },
    )
    return {
        "ok": True,
        "devices": merged,
        "local_devices": normalized_local,
        "cloud_devices": normalized_cloud,
        "file_name": file_name,
        "cloud_error": cloud_error,
        "local_count": len(normalized_local),
        "cloud_count": len(normalized_cloud),
        "saved_count": len(merged),
        "subnet_hint": (subnet_hint or "").strip(),
        "existing_file_name": existing_file_name,
        "existing_file_count": len(normalized_existing),
        "existing_only_count": existing_only_count,
        "local_lan_scan_count": local_lan_scan_count,
        "local_file_fallback_count": local_file_fallback_count,
        "local_scan_enabled": bool(local_result.get("enabled", True)),
        "local_scan_devices_file": str(local_result.get("devices_file", "")),
        "local_scan_devices_file_count": int(local_result.get("devices_file_count", 0) or 0),
        "devices_file_diagnostics": devices_file_diag,
        "cloud_cfg_presence": cloud_cfg_presence,
    }


def tuya_devices_file() -> dict[str, Any]:
    rows, file_name = _load_tuya_devices_file()
    normalized: list[dict[str, Any]] = []
    for row in rows:
        mode = "local_lan" if str(row.get("local_key", "")).strip() else "cloud"
        normalized.append(_normalize_tuya_row(dict(row), source="devices_file", mode=mode))
    merged = _merge_tuya_rows(normalized)
    return {
        "ok": True,
        "file_name": file_name,
        "count": len(merged),
        "devices": merged,
        "devices_file_diagnostics": _tuya_devices_file_diagnostics(),
    }
