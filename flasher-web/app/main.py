from __future__ import annotations

import json
import hashlib
import re
import time
import traceback
import uuid
from pathlib import Path
from typing import Any

import httpx
from fastapi import Depends, FastAPI, File, HTTPException, Request, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .auth import auth_status, login_admin, require_auth_if_configured, setup_admin
from .device_comm import fetch_device_status, push_ota_to_device, send_device_command
from .diagnostics import (
    extract_host_candidates,
    extract_ipv4_candidates,
    parse_serial_network_summary,
    ping_host,
    probe_status_quick,
    test_device_pair,
    test_device_status,
)
from .firmware_builder import FirmwareBuildError, build_firmware
from .flashing import get_flash_job, list_ports_for_flash, probe_serial_port, start_flash_job
from .integrations import spotify_action, spotify_now_playing, tuya_cloud_devices, tuya_local_scan, weather_current
from .moes import discover_bhubw_lights, discover_bhubw_local, get_bhubw_light_status, send_bhubw_light_command
from .ota import sign_firmware
from .profiles import (
    PROFILES_DIR,
    create_firmware_profile,
    get_firmware_profile,
    get_profile_file_paths,
    list_firmware_profiles,
)
from .scanner import scan_network
from .session_logs import SESSION_COOKIE_NAME, append_activity, append_error, get_or_create_client_session_id
from .serial_monitor import (
    get_serial_monitor,
    start_serial_monitor,
    stop_serial_monitor,
    stop_serial_monitors_for_port,
)
from .schemas import (
    DeviceCommandRequest,
    DeviceCreate,
    DeviceOTAPushRequest,
    DeviceUpdate,
    DisplayConfig,
    FlashJobCreate,
    FirmwareProfileCreate,
    IntegrationsConfig,
    OTASignRequest,
    TileCreate,
)
from .security import decrypt_secret, encrypt_secret, hash_passcode
from .storage import DATA_DIR, append_event, ensure_data_layout, get_connection, get_setting, init_db, set_setting, utc_now
from .tuya_provider import get_tuya_device_status, send_tuya_device_command
from .versioning import flasher_display_version, load_version_manifest

app = FastAPI(title="8bb Smart Controller Flasher", version=flasher_display_version())
STATIC_DIR = Path(__file__).resolve().parent / "static"
FIRMWARE_DIR = DATA_DIR / "firmware"
OTA_DIR = DATA_DIR / "ota"
FIRMWARE_PROFILES_DIR = DATA_DIR / "firmware_profiles"
ensure_data_layout()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/ui", StaticFiles(directory=STATIC_DIR), name="ui")
app.mount("/downloads/firmware", StaticFiles(directory=FIRMWARE_DIR), name="downloads_firmware")
app.mount("/downloads/ota", StaticFiles(directory=OTA_DIR), name="downloads_ota")
app.mount("/downloads/profiles", StaticFiles(directory=FIRMWARE_PROFILES_DIR), name="downloads_profiles")


@app.middleware("http")
async def request_session_logger(request: Request, call_next: Any) -> Response:
    start = time.perf_counter()
    req_id = str(uuid.uuid4())
    client_host = request.client.host if request.client else ""
    user_agent = request.headers.get("user-agent", "")
    auth_token = request.headers.get("x-auth-token", "")
    auth_token_hash = hashlib.sha256(auth_token.encode("utf-8")).hexdigest()[:12] if auth_token else ""

    cookie_session = request.cookies.get(SESSION_COOKIE_NAME, "")
    session_id, created = get_or_create_client_session_id(cookie_session)
    base_record: dict[str, Any] = {
        "request_id": req_id,
        "method": request.method,
        "path": request.url.path,
        "query": request.url.query or "",
        "client_host": client_host,
        "user_agent": user_agent,
        "auth_token_hash": auth_token_hash,
    }

    try:
        response = await call_next(request)
    except Exception as exc:
        elapsed_ms = int((time.perf_counter() - start) * 1000)
        err_record = {
            **base_record,
            "status": 500,
            "duration_ms": elapsed_ms,
            "error": str(exc),
            "traceback": traceback.format_exc(limit=30),
        }
        try:
            append_activity(session_id, err_record)
            append_error(session_id, err_record)
        except Exception:
            # Logging must never break API handling.
            pass
        raise

    elapsed_ms = int((time.perf_counter() - start) * 1000)
    status = int(response.status_code)
    activity_record = {**base_record, "status": status, "duration_ms": elapsed_ms}
    try:
        append_activity(session_id, activity_record)
        if status >= 400:
            append_error(session_id, {**activity_record, "error": f"HTTP {status}"})
    except Exception:
        # Logging must never break API handling.
        pass

    if created:
        response.set_cookie(
            key=SESSION_COOKIE_NAME,
            value=session_id,
            max_age=30 * 24 * 60 * 60,
            httponly=False,
            samesite="lax",
        )
    return response


@app.on_event("startup")
def on_startup() -> None:
    ensure_data_layout()
    init_db()


@app.get("/")
def web_root() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


def _device_to_dict(row: Any, conn: Any) -> dict[str, Any]:
    channels = conn.execute(
        "SELECT channel_key, channel_name, channel_kind, payload_json FROM device_channels WHERE device_id=? ORDER BY id ASC",
        (row["id"],),
    ).fetchall()

    return {
        "id": row["id"],
        "name": row["name"],
        "type": row["type"],
        "host": row["host"],
        "mac": row["mac"],
        "has_passcode": bool(row["passcode_hash"]),
        "ip_mode": row["ip_mode"],
        "static_ip": row["static_ip"],
        "gateway": row["gateway"],
        "subnet_mask": row["subnet_mask"],
        "metadata": json.loads(row["metadata_json"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "last_seen_at": row["last_seen_at"],
        "channels": [
            {
                "channel_key": c["channel_key"],
                "channel_name": c["channel_name"],
                "channel_kind": c["channel_kind"],
                "payload": json.loads(c["payload_json"]),
            }
            for c in channels
        ],
    }


def _decrypt_fields(obj: dict[str, Any], fields: list[str]) -> dict[str, Any]:
    out = dict(obj)
    for field in fields:
        if field in out:
            out[field] = decrypt_secret(out[field])
    return out


def _load_ota_shared_key() -> str:
    ota_cfg = get_setting("ota")
    return decrypt_secret(ota_cfg.get("shared_key", ""))


def _safe_filename(value: str, label: str = "filename") -> str:
    raw = (value or "").strip()
    if not raw:
        raise ValueError(f"{label} is required")
    name = Path(raw).name.strip()
    if not name:
        raise ValueError(f"{label} is invalid")
    if name != raw:
        raise ValueError(f"{label} must not include path separators")
    return name


def _parse_metadata(row: Any) -> dict[str, Any]:
    if isinstance(row, dict):
        if isinstance(row.get("metadata"), dict):
            return dict(row.get("metadata", {}))
        raw = row.get("metadata_json", "")
    else:
        raw = row["metadata_json"]
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


def _resolve_device_status(row: Any) -> dict[str, Any]:
    metadata = _parse_metadata(row)
    provider = str(metadata.get("provider", "")).strip().lower()
    if provider == "moes_bhubw":
        out = get_bhubw_light_status(metadata)
        out.setdefault("source_name", metadata.get("source_name", "MOES BHUB-W"))
        return out
    if provider in ("tuya_local", "tuya_cloud", "tuya"):
        out = get_tuya_device_status(metadata)
        if provider == "tuya_cloud":
            out.setdefault("source_name", metadata.get("source_name", "Tuya Cloud"))
        else:
            out.setdefault("source_name", metadata.get("source_name", "Tuya Local"))
        return out

    host = str(row["host"] or "").strip()
    if not host:
        raise ValueError("Device host is not set")
    status = fetch_device_status(host)
    if isinstance(status, dict) and "device_type" not in status:
        status["device_type"] = row["type"]
    if isinstance(status, dict):
        status.setdefault("provider", "esp_firmware")
        status.setdefault("mode", "local_lan")
        status.setdefault("source_name", metadata.get("source_name", "8bb Firmware"))
    return status


def _require_device(device_id: str) -> tuple[Any, Any]:
    conn = get_connection()
    row = conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="Device not found")
    return conn, row


def _slug_value(value: str, fallback: str = "item") -> str:
    raw = re.sub(r"[^a-zA-Z0-9_-]+", "-", (value or "").strip().lower()).strip("-")
    return raw[:64] if raw else fallback


def _parse_major_minor(version: str) -> tuple[int, int | None]:
    m = re.match(r"^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?\s*$", (version or "").strip())
    if not m:
        return 1, None
    major = int(m.group(1))
    minor = int(m.group(2)) if m.group(2) is not None else None
    return major, minor


def _next_build_version(profile_name: str, device_type: str, requested_version: str) -> str:
    key = f"{_slug_value(profile_name, 'profile')}::{_slug_value(device_type, 'device')}"
    major, requested_minor = _parse_major_minor(requested_version)

    counters = get_setting("build_counters")
    if not isinstance(counters, dict):
        counters = {}

    entry = counters.get(key, {})
    try:
        last_major = int(entry.get("major", major))
    except Exception:
        last_major = major
    try:
        last_minor = int(entry.get("minor", 0))
    except Exception:
        last_minor = 0

    if key not in counters or last_major != major:
        base = requested_minor if (requested_minor is not None and requested_minor >= 0) else 0
        next_minor = base + 1
    else:
        next_minor = last_minor + 1

    resolved = f"{major}.{next_minor:02d}"
    counters[key] = {"major": major, "minor": next_minor, "updated_at": utc_now()}
    set_setting("build_counters", counters)
    return resolved


def _has_active_flash_job(port: str | None = None) -> bool:
    conn = get_connection()
    if port:
        row = conn.execute(
            "SELECT id FROM flash_jobs WHERE status IN ('queued','running') AND lower(port)=lower(?) LIMIT 1",
            (port.strip(),),
        ).fetchone()
    else:
        row = conn.execute(
            "SELECT id FROM flash_jobs WHERE status IN ('queued','running') LIMIT 1",
        ).fetchone()
    conn.close()
    return bool(row)


@app.get("/api/system/health")
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "data_dir": str(DATA_DIR),
        "time": utc_now(),
    }


@app.get("/api/system/version")
def system_version() -> dict[str, Any]:
    manifest = load_version_manifest()
    return {
        "controller": manifest.get("controller", {}),
        "flasher": manifest.get("flasher", {}),
        "flasher_display": flasher_display_version(),
        "updated_at": manifest.get("updated_at", ""),
    }


@app.get("/api/auth/status")
def get_auth_status() -> dict[str, bool]:
    return auth_status()


@app.post("/api/auth/setup")
def post_auth_setup(payload: dict[str, str]) -> dict[str, bool]:
    username = payload.get("username", "").strip()
    password = payload.get("password", "").strip()
    if not username or not password:
        raise HTTPException(status_code=400, detail="username and password are required")
    try:
        setup_admin(username, password)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    append_event("admin_setup", {"username": username})
    return {"configured": True}


@app.post("/api/auth/login")
def post_auth_login(payload: dict[str, str]) -> dict[str, str]:
    username = payload.get("username", "").strip()
    password = payload.get("password", "").strip()
    try:
        token = login_admin(username, password)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except PermissionError as exc:
        raise HTTPException(status_code=401, detail=str(exc)) from exc
    return {"token": token}


@app.get("/api/auth/validate", dependencies=[Depends(require_auth_if_configured)])
def get_auth_validate() -> dict[str, bool]:
    return {"ok": True}


@app.get("/api/config/display")
def get_display() -> dict[str, Any]:
    return get_setting("display")


@app.put("/api/config/display", dependencies=[Depends(require_auth_if_configured)])
def put_display(payload: DisplayConfig) -> dict[str, Any]:
    data = payload.model_dump()
    set_setting("display", data)
    append_event("display_updated", data)
    return data


@app.get("/api/config/integrations")
def get_integrations() -> dict[str, Any]:
    spotify = get_setting("spotify")
    weather = get_setting("weather")
    tuya = get_setting("tuya")
    scan = get_setting("scan")
    moes = get_setting("moes")
    ota = get_setting("ota")
    return {
        "spotify": _decrypt_fields(spotify, ["client_secret", "refresh_token"]),
        "weather": _decrypt_fields(weather, ["api_key"]),
        "tuya": _decrypt_fields(tuya, ["client_secret"]),
        "scan": scan,
        "moes": _decrypt_fields(moes, ["hub_local_key"]),
        "ota": _decrypt_fields(ota, ["shared_key"]),
    }


@app.put("/api/config/integrations", dependencies=[Depends(require_auth_if_configured)])
def put_integrations(payload: IntegrationsConfig) -> dict[str, Any]:
    data = payload.model_dump()
    data["spotify"]["client_secret"] = encrypt_secret(data["spotify"].get("client_secret", ""))
    data["spotify"]["refresh_token"] = encrypt_secret(data["spotify"].get("refresh_token", ""))
    data["weather"]["api_key"] = encrypt_secret(data["weather"].get("api_key", ""))
    data["tuya"]["client_secret"] = encrypt_secret(data["tuya"].get("client_secret", ""))
    data["moes"]["hub_local_key"] = encrypt_secret(data["moes"].get("hub_local_key", ""))
    data["ota"]["shared_key"] = encrypt_secret(data["ota"].get("shared_key", ""))

    set_setting("spotify", data["spotify"])
    set_setting("weather", data["weather"])
    set_setting("tuya", data["tuya"])
    set_setting("scan", data["scan"])
    set_setting("moes", data["moes"])
    set_setting("ota", data["ota"])
    append_event("integrations_updated", {"scan": data["scan"]})
    return {"saved": True}


@app.post("/api/integrations/moes/discover-local", dependencies=[Depends(require_auth_if_configured)])
def post_moes_discover_local(payload: dict[str, Any]) -> dict[str, Any]:
    subnet_hint = ""
    if isinstance(payload, dict):
        subnet_hint = str(payload.get("subnet_hint", "")).strip()
    try:
        return discover_bhubw_local(subnet_hint=subnet_hint)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/moes/discover-lights", dependencies=[Depends(require_auth_if_configured)])
def post_moes_discover_lights(payload: dict[str, Any]) -> dict[str, Any]:
    hub_device_id = ""
    hub_ip = ""
    hub_local_key = ""
    hub_version = ""
    if isinstance(payload, dict):
        hub_device_id = str(payload.get("hub_device_id", "")).strip()
        hub_ip = str(payload.get("hub_ip", "")).strip()
        hub_local_key = str(payload.get("hub_local_key", "")).strip()
        hub_version = str(payload.get("hub_version", "")).strip()
    try:
        return discover_bhubw_lights(
            hub_device_id=hub_device_id,
            hub_ip=hub_ip,
            hub_local_key=hub_local_key,
            hub_version=hub_version,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/integrations/spotify/now-playing")
def get_spotify_now_playing() -> dict[str, Any]:
    try:
        return spotify_now_playing()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/spotify/action", dependencies=[Depends(require_auth_if_configured)])
def post_spotify_action(payload: dict[str, str]) -> dict[str, Any]:
    action = payload.get("action", "").strip().lower()
    try:
        return spotify_action(action)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/integrations/weather/current")
def get_weather_current() -> dict[str, Any]:
    try:
        return weather_current()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/tuya/local-scan", dependencies=[Depends(require_auth_if_configured)])
def post_tuya_local_scan() -> dict[str, Any]:
    try:
        return tuya_local_scan()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/tuya/cloud-devices", dependencies=[Depends(require_auth_if_configured)])
def post_tuya_cloud_devices() -> dict[str, Any]:
    try:
        return tuya_cloud_devices()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/devices")
def list_devices() -> list[dict[str, Any]]:
    conn = get_connection()
    rows = conn.execute("SELECT * FROM devices ORDER BY updated_at DESC").fetchall()
    items = [_device_to_dict(r, conn) for r in rows]
    conn.close()
    return items


@app.post("/api/devices", dependencies=[Depends(require_auth_if_configured)])
def create_device(payload: DeviceCreate) -> dict[str, Any]:
    device_id = str(uuid.uuid4())
    now = utc_now()
    passcode_hash = hash_passcode(payload.passcode) if payload.passcode else None
    passcode_enc = encrypt_secret(payload.passcode or "")

    conn = get_connection()
    conn.execute(
        """
        INSERT INTO devices(id, name, type, host, mac, passcode_hash, passcode_enc, ip_mode, static_ip, gateway, subnet_mask, metadata_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            device_id,
            payload.name,
            payload.type,
            payload.host,
            payload.mac,
            passcode_hash,
            passcode_enc,
            payload.ip_mode,
            payload.static_ip,
            payload.gateway,
            payload.subnet_mask,
            json.dumps(payload.metadata),
            now,
            now,
        ),
    )

    for ch in payload.channels:
        conn.execute(
            """
            INSERT INTO device_channels(device_id, channel_key, channel_name, channel_kind, payload_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                device_id,
                ch.channel_key,
                ch.channel_name,
                ch.channel_kind,
                json.dumps(ch.payload),
                now,
                now,
            ),
        )

    conn.commit()
    row = conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
    data = _device_to_dict(row, conn)
    conn.close()

    append_event("device_created", {"id": device_id, "name": payload.name, "type": payload.type})
    return data


@app.get("/api/devices/{device_id}")
def get_device(device_id: str) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    data = _device_to_dict(row, conn)
    conn.close()
    return data


@app.patch("/api/devices/{device_id}", dependencies=[Depends(require_auth_if_configured)])
def patch_device(device_id: str, payload: DeviceUpdate) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    current = dict(row)
    updates = payload.model_dump(exclude_none=True)

    if "passcode" in updates:
        new_pass = updates.pop("passcode")
        current["passcode_hash"] = hash_passcode(new_pass)
        current["passcode_enc"] = encrypt_secret(new_pass)
    if "metadata" in updates:
        current["metadata_json"] = json.dumps(updates.pop("metadata"))

    for k, v in updates.items():
        current[k] = v
    current["updated_at"] = utc_now()

    conn.execute(
        """
        UPDATE devices
        SET name=?, host=?, mac=?, passcode_hash=?, passcode_enc=?, ip_mode=?, static_ip=?, gateway=?, subnet_mask=?, metadata_json=?, updated_at=?
        WHERE id=?
        """,
        (
            current["name"],
            current["host"],
            current["mac"],
            current["passcode_hash"],
            current["passcode_enc"],
            current["ip_mode"],
            current["static_ip"],
            current["gateway"],
            current["subnet_mask"],
            current["metadata_json"],
            current["updated_at"],
            device_id,
        ),
    )
    conn.commit()
    updated_row = conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
    data = _device_to_dict(updated_row, conn)
    conn.close()
    append_event("device_updated", {"id": device_id, "fields": list(updates.keys())})
    return data


@app.delete("/api/devices/{device_id}", dependencies=[Depends(require_auth_if_configured)])
def delete_device(device_id: str) -> dict[str, Any]:
    conn = get_connection()
    count = conn.execute("DELETE FROM devices WHERE id=?", (device_id,)).rowcount
    conn.commit()
    conn.close()
    if count == 0:
        raise HTTPException(status_code=404, detail="Device not found")
    append_event("device_removed", {"id": device_id})
    return {"removed": True}


@app.post("/api/devices/{device_id}/channels", dependencies=[Depends(require_auth_if_configured)])
def upsert_channel(device_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    required = ["channel_key", "channel_name", "channel_kind"]
    for field in required:
        if field not in payload:
            raise HTTPException(status_code=400, detail=f"Missing field: {field}")

    now = utc_now()
    conn, _ = _require_device(device_id)
    conn.execute(
        """
        INSERT INTO device_channels(device_id, channel_key, channel_name, channel_kind, payload_json, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(device_id, channel_key)
        DO UPDATE SET channel_name=excluded.channel_name, channel_kind=excluded.channel_kind, payload_json=excluded.payload_json, updated_at=excluded.updated_at
        """,
        (
            device_id,
            payload["channel_key"],
            payload["channel_name"],
            payload["channel_kind"],
            json.dumps(payload.get("payload", {})),
            now,
            now,
        ),
    )
    conn.commit()
    conn.close()
    append_event("device_channel_upserted", {"device_id": device_id, "channel_key": payload["channel_key"]})
    return {"saved": True}


@app.post("/api/devices/{device_id}/rescan", dependencies=[Depends(require_auth_if_configured)])
def rescan_device(device_id: str) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    try:
        status = _resolve_device_status(row)
    except ValueError as exc:
        conn.close()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        conn.close()
        raise HTTPException(status_code=502, detail=f"Device rescan failed: {exc}") from exc
    except Exception as exc:
        conn.close()
        raise HTTPException(status_code=502, detail=f"Device rescan failed: {exc}") from exc

    now = utc_now()
    metadata = _parse_metadata(row)
    metadata["last_status"] = status
    conn.execute(
        "UPDATE devices SET metadata_json=?, last_seen_at=?, updated_at=? WHERE id=?",
        (json.dumps(metadata), now, now, device_id),
    )
    conn.commit()
    conn.close()
    append_event("device_rescanned", {"id": device_id})
    return {"rescanned": True, "last_seen_at": now, "status": status}


@app.get("/api/devices/{device_id}/status")
def get_device_status(device_id: str) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    try:
        status = _resolve_device_status(row)
    except ValueError as exc:
        conn.close()
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        conn.close()
        raise HTTPException(status_code=502, detail=f"Device status failed: {exc}") from exc
    except Exception as exc:
        conn.close()
        raise HTTPException(status_code=502, detail=f"Device status failed: {exc}") from exc

    now = utc_now()
    conn.execute("UPDATE devices SET last_seen_at=?, updated_at=? WHERE id=?", (now, now, device_id))
    conn.commit()
    conn.close()
    return status


@app.post("/api/devices/{device_id}/command", dependencies=[Depends(require_auth_if_configured)])
def post_device_command(device_id: str, payload: DeviceCommandRequest) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    host = (row["host"] or "").strip()
    passcode = decrypt_secret(row["passcode_enc"] or "")
    metadata = _parse_metadata(row)
    conn.close()

    cmd = payload.model_dump()
    provider = str(metadata.get("provider", "")).strip().lower()
    if provider == "moes_bhubw":
        try:
            result = send_bhubw_light_command(metadata=metadata, command=cmd)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"MOES local command failed: {exc}") from exc
        append_event("device_command", {"device_id": device_id, "channel": payload.channel, "state": payload.state, "provider": "moes_bhubw"})
        return result
    if provider in ("tuya_local", "tuya_cloud", "tuya"):
        try:
            result = send_tuya_device_command(metadata=metadata, command=cmd)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Tuya command failed: {exc}") from exc
        append_event("device_command", {"device_id": device_id, "channel": payload.channel, "state": payload.state, "provider": provider})
        return result

    if not host:
        raise HTTPException(status_code=400, detail="Device host is not set")
    if not passcode:
        raise HTTPException(status_code=400, detail="Device passcode is not configured")

    cmd.update(payload.payload)
    try:
        result = send_device_command(host, passcode, cmd)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Device command failed: {exc}") from exc
    append_event("device_command", {"device_id": device_id, "channel": payload.channel, "state": payload.state})
    return result


@app.post("/api/devices/{device_id}/ota/push", dependencies=[Depends(require_auth_if_configured)])
def push_device_ota(device_id: str, payload: DeviceOTAPushRequest, request: Request) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    host = (row["host"] or "").strip()
    passcode = decrypt_secret(row["passcode_enc"] or "")
    device_type = row["type"]
    conn.close()

    if not host:
        raise HTTPException(status_code=400, detail="Device host is not set")
    if not passcode:
        raise HTTPException(status_code=400, detail="Device passcode is not configured")

    shared_key = _load_ota_shared_key()
    if not shared_key:
        raise HTTPException(status_code=400, detail="OTA shared key is not configured")

    try:
        firmware_filename = _safe_filename(payload.firmware_filename, "firmware_filename")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    firmware_path = FIRMWARE_DIR / firmware_filename
    try:
        signed = sign_firmware(firmware_path, payload.version, device_type, shared_key)
    except (FileNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    base = str(request.base_url).rstrip("/")
    firmware_url = f"{base}/downloads/firmware/{firmware_filename}"
    manifest_name = Path(signed["manifest_path"]).name
    manifest_url = f"{base}/downloads/ota/{manifest_name}"

    try:
        result = push_ota_to_device(host, passcode, firmware_url, manifest_url)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"OTA push failed: {exc}") from exc
    append_event("device_ota_push", {"device_id": device_id, "firmware": firmware_filename, "version": payload.version})
    return {"ok": True, "device_response": result, "manifest": signed["manifest"]}


@app.get("/api/main/tiles")
def list_tiles() -> list[dict[str, Any]]:
    conn = get_connection()
    rows = conn.execute("SELECT * FROM main_tiles ORDER BY updated_at DESC").fetchall()
    conn.close()
    return [
        {
            "id": r["id"],
            "tile_type": r["tile_type"],
            "ref_id": r["ref_id"],
            "label": r["label"],
            "payload": json.loads(r["payload_json"]),
            "created_at": r["created_at"],
            "updated_at": r["updated_at"],
        }
        for r in rows
    ]


@app.get("/api/main/tile-data")
def get_tile_data() -> dict[str, Any]:
    conn = get_connection()
    rows = conn.execute("SELECT * FROM main_tiles ORDER BY updated_at DESC").fetchall()
    device_map = {r["id"]: dict(r) for r in conn.execute("SELECT * FROM devices").fetchall()}
    conn.close()

    tiles = []
    for row in rows:
        tile = {
            "id": row["id"],
            "tile_type": row["tile_type"],
            "label": row["label"],
            "ref_id": row["ref_id"],
            "payload": json.loads(row["payload_json"]),
            "data": {},
            "error": None,
        }
        try:
            if row["tile_type"] == "weather":
                tile["data"] = weather_current()
            elif row["tile_type"] == "spotify":
                tile["data"] = spotify_now_playing()
            elif row["tile_type"] == "device" and row["ref_id"] in device_map:
                dev = device_map[row["ref_id"]]
                tile["data"] = _resolve_device_status(dev)
                tile["data"]["device_type"] = dev.get("type")
        except Exception as exc:  # best-effort dashboard render
            tile["error"] = str(exc)
        tiles.append(tile)
    return {"tiles": tiles}


@app.post("/api/main/tiles", dependencies=[Depends(require_auth_if_configured)])
def create_tile(payload: TileCreate) -> dict[str, Any]:
    tile_id = str(uuid.uuid4())
    now = utc_now()
    conn = get_connection()
    conn.execute(
        "INSERT INTO main_tiles(id, tile_type, ref_id, label, payload_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (tile_id, payload.tile_type, payload.ref_id, payload.label, json.dumps(payload.payload), now, now),
    )
    conn.commit()
    conn.close()
    append_event("tile_created", {"id": tile_id, "label": payload.label, "tile_type": payload.tile_type})
    return {"id": tile_id}


@app.delete("/api/main/tiles/{tile_id}", dependencies=[Depends(require_auth_if_configured)])
def delete_tile(tile_id: str) -> dict[str, Any]:
    conn = get_connection()
    count = conn.execute("DELETE FROM main_tiles WHERE id=?", (tile_id,)).rowcount
    conn.commit()
    conn.close()
    if count == 0:
        raise HTTPException(status_code=404, detail="Tile not found")
    append_event("tile_removed", {"id": tile_id})
    return {"removed": True}


@app.post("/api/discovery/scan", dependencies=[Depends(require_auth_if_configured)])
def discovery_scan(payload: dict[str, Any]) -> dict[str, Any]:
    subnet = payload.get("subnet_hint") if isinstance(payload, dict) else None
    results = scan_network(subnet)
    append_event("network_scan", {"count": len(results), "subnet_hint": subnet or ""})
    return {"results": results}


@app.post("/api/flash/jobs", dependencies=[Depends(require_auth_if_configured)])
def create_flash_job(payload: FlashJobCreate) -> dict[str, Any]:
    try:
        port = str(payload.port or "").strip()
        if not port:
            raise ValueError("port is required")
        if _has_active_flash_job(port):
            raise HTTPException(status_code=409, detail=f"Flash already running on {port}")
        stopped = stop_serial_monitors_for_port(port)
        if stopped:
            append_event("serial_monitor_stopped_for_flash", {"port": port, "sessions": stopped})
        firmware_filename = _safe_filename(payload.firmware_filename, "firmware_filename")
        return start_flash_job(
            device_id=payload.device_id,
            port=port,
            baud=payload.baud,
            firmware_filename=firmware_filename,
        )
    except HTTPException:
        raise
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/api/flash/jobs/{job_id}")
def read_flash_job(job_id: str) -> dict[str, Any]:
    job = get_flash_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


@app.post("/api/serial/monitor/start", dependencies=[Depends(require_auth_if_configured)])
def post_serial_monitor_start(payload: dict[str, Any]) -> dict[str, Any]:
    port = str(payload.get("port", "")).strip() if isinstance(payload, dict) else ""
    baud_raw = payload.get("baud", 115200) if isinstance(payload, dict) else 115200
    try:
        baud = int(baud_raw)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="baud must be a valid integer") from exc
    try:
        if _has_active_flash_job(port):
            raise HTTPException(status_code=409, detail=f"Flash in progress on {port}. Wait for it to finish.")
        stopped = stop_serial_monitors_for_port(port)
        if stopped:
            append_event("serial_monitor_replaced", {"port": port, "sessions": stopped})
        return start_serial_monitor(port=port, baud=baud)
    except HTTPException:
        raise
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/serial/monitor/{session_id}", dependencies=[Depends(require_auth_if_configured)])
def get_serial_monitor_status(session_id: str) -> dict[str, Any]:
    try:
        return get_serial_monitor(session_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/api/serial/monitor/{session_id}/stop", dependencies=[Depends(require_auth_if_configured)])
def post_serial_monitor_stop(session_id: str) -> dict[str, Any]:
    try:
        return stop_serial_monitor(session_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.post("/api/serial/probe", dependencies=[Depends(require_auth_if_configured)])
def post_serial_probe(payload: dict[str, Any]) -> dict[str, Any]:
    port = str(payload.get("port", "")).strip() if isinstance(payload, dict) else ""
    baud_raw = payload.get("baud", 115200) if isinstance(payload, dict) else 115200
    try:
        baud = int(baud_raw)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="baud must be a valid integer") from exc
    try:
        if _has_active_flash_job(port):
            raise HTTPException(status_code=409, detail=f"Flash in progress on {port}. Wait for it to finish.")
        stopped = stop_serial_monitors_for_port(port)
        if stopped:
            append_event("serial_monitor_stopped_for_probe", {"port": port, "sessions": stopped})
        return probe_serial_port(port=port, baud=baud)
    except HTTPException:
        raise
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/diagnostics/extract-ip", dependencies=[Depends(require_auth_if_configured)])
def post_diag_extract_ip(payload: dict[str, Any]) -> dict[str, Any]:
    source_text = ""
    session_id = ""
    if isinstance(payload, dict):
        session_id = str(payload.get("session_id", "")).strip()
        source_text = str(payload.get("text", "") or "")
    if session_id:
        try:
            mon = get_serial_monitor(session_id)
            source_text = str(mon.get("output", "") or "")
        except KeyError:
            pass
    ips = extract_ipv4_candidates(source_text)
    return {"ips": ips, "count": len(ips)}


@app.post("/api/diagnostics/parse-serial", dependencies=[Depends(require_auth_if_configured)])
def post_diag_parse_serial(payload: dict[str, Any]) -> dict[str, Any]:
    source_text = ""
    session_id = ""
    if isinstance(payload, dict):
        session_id = str(payload.get("session_id", "")).strip()
        source_text = str(payload.get("text", "") or "")
    if session_id:
        try:
            mon = get_serial_monitor(session_id)
            source_text = str(mon.get("output", "") or "")
        except KeyError:
            pass
    return parse_serial_network_summary(source_text)


@app.post("/api/diagnostics/ping", dependencies=[Depends(require_auth_if_configured)])
def post_diag_ping(payload: dict[str, Any]) -> dict[str, Any]:
    host = str(payload.get("host", "")).strip() if isinstance(payload, dict) else ""
    if not host:
        raise HTTPException(status_code=400, detail="host is required")
    try:
        return ping_host(host)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/diagnostics/status", dependencies=[Depends(require_auth_if_configured)])
def post_diag_status(payload: dict[str, Any]) -> dict[str, Any]:
    host = str(payload.get("host", "")).strip() if isinstance(payload, dict) else ""
    if not host:
        raise HTTPException(status_code=400, detail="host is required")
    return test_device_status(host)


@app.post("/api/diagnostics/pair", dependencies=[Depends(require_auth_if_configured)])
def post_diag_pair(payload: dict[str, Any]) -> dict[str, Any]:
    host = str(payload.get("host", "")).strip() if isinstance(payload, dict) else ""
    passcode = str(payload.get("passcode", "")) if isinstance(payload, dict) else ""
    if not host:
        raise HTTPException(status_code=400, detail="host is required")
    if not passcode:
        raise HTTPException(status_code=400, detail="passcode is required")
    return test_device_pair(host, passcode)


def _diag_auto_discover_core(payload: dict[str, Any]) -> dict[str, Any]:
    session_id = str(payload.get("session_id", "")).strip() if isinstance(payload, dict) else ""
    expected_hostname = str(payload.get("expected_hostname", "")).strip() if isinstance(payload, dict) else ""
    passcode = str(payload.get("passcode", "")) if isinstance(payload, dict) else ""
    text = str(payload.get("text", "") or "") if isinstance(payload, dict) else ""

    if session_id:
        try:
            mon = get_serial_monitor(session_id)
            text = str(mon.get("output", "") or "")
        except KeyError:
            pass

    candidates: list[str] = []
    ips = extract_ipv4_candidates(text)
    hosts = extract_host_candidates(text)
    candidates.extend(ips)
    candidates.extend(hosts)

    if expected_hostname:
        candidates.append(expected_hostname)
        if "." not in expected_hostname:
            candidates.append(f"{expected_hostname}.local")

    # LAN fallback when serial doesn't print IP/hostname.
    scan_rows = scan_network(None, resolve_hostnames=True)
    for row in scan_rows:
        ip = str(row.get("ip", "")).strip()
        hostname = str(row.get("hostname", "")).strip()
        if ip:
            candidates.append(ip)
        if hostname:
            candidates.append(hostname)

    deduped: list[str] = []
    seen: set[str] = set()
    for item in candidates:
        host = item.strip()
        if not host:
            continue
        key = host.lower()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(host)

    checks: list[dict[str, Any]] = []
    best: dict[str, Any] | None = None
    for host in deduped[:40]:
        status_check = probe_status_quick(host, timeout=1.3)
        if status_check.get("ok"):
            best = status_check
            break
        checks.append({"host": host, "ok": False, "error": status_check.get("error", "")})

    pair_check: dict[str, Any] | None = None
    if best and passcode:
        pair_check = test_device_pair(str(best.get("host", "")), passcode)

    return {
        "ok": bool(best and best.get("ok")),
        "detected_host": best.get("host") if best else "",
        "detected_status": best.get("status") if best else {},
        "pair": pair_check or {"ok": False, "error": "passcode missing or no host found"},
        "source": {
            "serial_session_id": session_id,
            "expected_hostname": expected_hostname,
            "serial_ip_candidates": ips,
            "serial_host_candidates": hosts,
            "candidate_count": len(deduped),
        },
        "attempts": checks[-20:],
    }


@app.post("/api/diagnostics/run-all", dependencies=[Depends(require_auth_if_configured)])
def post_diag_run_all(payload: dict[str, Any]) -> dict[str, Any]:
    host = str(payload.get("host", "")).strip() if isinstance(payload, dict) else ""
    passcode = str(payload.get("passcode", "")) if isinstance(payload, dict) else ""
    discovered: dict[str, Any] | None = None
    if not host:
        discovered = _diag_auto_discover_core(payload if isinstance(payload, dict) else {})
        host = str(discovered.get("detected_host", "")).strip()
    if not host:
        raise HTTPException(status_code=400, detail="host is required or auto-discovery did not find a reachable device")
    out: dict[str, Any] = {"host": host}
    if discovered:
        out["auto_discover"] = discovered
    try:
        out["ping"] = ping_host(host)
    except Exception as exc:
        out["ping"] = {"ok": False, "error": str(exc)}
    out["status"] = test_device_status(host)
    if passcode:
        out["pair"] = test_device_pair(host, passcode)
    else:
        out["pair"] = {"ok": False, "error": "passcode missing"}
    out["ok"] = bool(out["ping"].get("ok")) and bool(out["status"].get("ok")) and bool(out["pair"].get("ok"))
    return out


@app.post("/api/diagnostics/auto-discover", dependencies=[Depends(require_auth_if_configured)])
def post_diag_auto_discover(payload: dict[str, Any]) -> dict[str, Any]:
    return _diag_auto_discover_core(payload if isinstance(payload, dict) else {})


@app.post("/api/ota/sign", dependencies=[Depends(require_auth_if_configured)])
def ota_sign(payload: OTASignRequest) -> dict[str, Any]:
    shared_key = _load_ota_shared_key()
    if not shared_key:
        raise HTTPException(status_code=400, detail="OTA shared key is not configured")
    try:
        firmware_filename = _safe_filename(payload.firmware_filename, "firmware_filename")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    firmware_path = FIRMWARE_DIR / firmware_filename
    try:
        return sign_firmware(firmware_path, payload.version, payload.device_type, shared_key)
    except (FileNotFoundError, ValueError) as exc:
        status = 404 if isinstance(exc, FileNotFoundError) else 400
        raise HTTPException(status_code=status, detail=str(exc)) from exc


@app.post("/api/firmware/profiles", dependencies=[Depends(require_auth_if_configured)])
def create_profile(payload: FirmwareProfileCreate) -> dict[str, Any]:
    shared_key = _load_ota_shared_key()
    if not shared_key:
        raise HTTPException(status_code=400, detail="OTA shared key is not configured")
    try:
        firmware_filename = _safe_filename(payload.firmware_filename, "firmware_filename")
        return create_firmware_profile(
            firmware_dir=FIRMWARE_DIR,
            profile_name=payload.profile_name,
            firmware_filename=firmware_filename,
            version=payload.version,
            device_type=payload.device_type,
            settings=payload.settings,
            notes=payload.notes,
            shared_key=shared_key,
        )
    except (FileNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/firmware/profiles")
def list_profiles() -> dict[str, Any]:
    return {"profiles": list_firmware_profiles()}


@app.get("/api/firmware/profiles/{profile_id}")
def get_profile(profile_id: str) -> dict[str, Any]:
    profile = get_firmware_profile(profile_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Profile not found")
    return profile


@app.post("/api/firmware/profiles/{profile_id}/push/{device_id}", dependencies=[Depends(require_auth_if_configured)])
def push_profile_to_device(profile_id: str, device_id: str, request: Request) -> dict[str, Any]:
    profile = get_firmware_profile(profile_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Profile not found")

    conn, row = _require_device(device_id)
    host = (row["host"] or "").strip()
    passcode = decrypt_secret(row["passcode_enc"] or "")
    conn.close()
    if not host:
        raise HTTPException(status_code=400, detail="Device host is not set")
    if not passcode:
        raise HTTPException(status_code=400, detail="Device passcode is not configured")

    try:
        firmware_path, manifest_path = get_profile_file_paths(profile)
    except (FileNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    profile_folder = profile.get("profile_folder", "")
    firmware_name = firmware_path.name
    manifest_name = manifest_path.name
    base = str(request.base_url).rstrip("/")
    firmware_url = f"{base}/downloads/profiles/{profile_folder}/{firmware_name}"
    manifest_url = f"{base}/downloads/profiles/{profile_folder}/{manifest_name}"

    try:
        result = push_ota_to_device(host, passcode, firmware_url, manifest_url)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Profile OTA push failed: {exc}") from exc
    append_event("firmware_profile_pushed", {"profile_id": profile_id, "device_id": device_id})
    return {"ok": True, "profile_id": profile_id, "device_id": device_id, "device_response": result}


@app.post("/api/firmware/build", dependencies=[Depends(require_auth_if_configured)])
def post_build_firmware(payload: dict[str, Any]) -> dict[str, Any]:
    profile_name = str(payload.get("profile_name", "profile")).strip() if isinstance(payload, dict) else "profile"
    requested_version = str(payload.get("version", "1.0.0")).strip() if isinstance(payload, dict) else "1.0.0"
    device_type = str(payload.get("device_type", "relay_switch")).strip() if isinstance(payload, dict) else "relay_switch"
    defaults = payload.get("defaults", {}) if isinstance(payload, dict) else {}
    if not isinstance(defaults, dict):
        defaults = {}
    version = _next_build_version(profile_name, device_type, requested_version)
    try:
        result = build_firmware(
            profile_name=profile_name,
            version=version,
            device_type=device_type,
            defaults=defaults,
        )
    except FirmwareBuildError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except (RuntimeError, FileNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {
        "ok": True,
        "build_id": result.get("build_id", ""),
        "log_file": result.get("log_file", ""),
        "ota_firmware_filename": result.get("ota_firmware_filename", ""),
        "serial_firmware_filename": result.get("serial_firmware_filename", ""),
        "build_log": result.get("build_log", ""),
        "merge_log": result.get("merge_log", ""),
        "version": version,
    }


@app.get("/api/files/firmware")
def list_firmware() -> list[str]:
    FIRMWARE_DIR.mkdir(parents=True, exist_ok=True)
    return sorted(p.name for p in FIRMWARE_DIR.glob("*.bin"))


@app.post("/api/files/firmware/upload", dependencies=[Depends(require_auth_if_configured)])
async def upload_firmware(file: UploadFile = File(...)) -> dict[str, Any]:
    filename = Path(file.filename or "").name
    if not filename.endswith(".bin"):
        raise HTTPException(status_code=400, detail="Only .bin firmware files are supported")
    destination = FIRMWARE_DIR / filename
    total = 0
    with destination.open("wb") as fp:
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            fp.write(chunk)
    append_event("firmware_uploaded", {"filename": filename, "bytes": total})
    return {"ok": True, "filename": filename, "bytes": total}


@app.get("/api/flash/ports")
def list_flash_ports() -> list[dict[str, Any]]:
    return list_ports_for_flash()


@app.get("/api/files/ota")
def list_ota_manifests() -> list[str]:
    OTA_DIR.mkdir(parents=True, exist_ok=True)
    return sorted(p.name for p in OTA_DIR.glob("*.manifest.json"))
