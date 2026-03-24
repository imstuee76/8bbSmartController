from __future__ import annotations

import json
import hashlib
import ipaddress
import os
import re
import socket
import threading
import time
import traceback
import uuid
from concurrent.futures import FIRST_COMPLETED, TimeoutError as FuturesTimeoutError, ThreadPoolExecutor, wait
from pathlib import Path
from typing import Any
from urllib.parse import urlparse, urlunparse

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
from .integrations import (
    spotify_action,
    spotify_now_playing,
    tuya_cloud_devices,
    tuya_devices_file,
    tuya_local_scan,
    tuya_scan_and_save,
    tuya_test_credentials,
    weather_current,
)
from .moes import (
    discover_bhubw_lights,
    discover_bhubw_local,
    get_bhubw_light_status,
    send_bhubw_light_command,
    test_bhubw_connection,
)
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
ROOT_DIR = Path(__file__).resolve().parents[2]
CONTROLLER_WEB_DIR = Path(
    os.environ.get("CONTROLLER_WEB_DIR", str(ROOT_DIR / "controller-app" / "build" / "web"))
).resolve()
FIRMWARE_DIR = DATA_DIR / "firmware"
OTA_DIR = DATA_DIR / "ota"
FIRMWARE_PROFILES_DIR = DATA_DIR / "firmware_profiles"
ensure_data_layout()

_DASHBOARD_DEVICE_CACHE_TTL_SECONDS = float(os.environ.get("DASHBOARD_DEVICE_CACHE_TTL_SECONDS", "12"))
_DASHBOARD_TASK_TIMEOUT_SECONDS = float(os.environ.get("DASHBOARD_TASK_TIMEOUT_SECONDS", "2.5"))
_DASHBOARD_TOTAL_TIMEOUT_SECONDS = float(os.environ.get("DASHBOARD_TOTAL_TIMEOUT_SECONDS", "6.0"))
_dashboard_device_cache: dict[str, dict[str, Any]] = {}
_PROFILE_PUSH_JOB_WORKERS = max(1, min(6, int(os.environ.get("PROFILE_PUSH_JOB_WORKERS", "3"))))
_profile_push_executor = ThreadPoolExecutor(max_workers=_PROFILE_PUSH_JOB_WORKERS)
_profile_push_jobs_lock = threading.Lock()
_profile_push_jobs: dict[str, dict[str, Any]] = {}
OTA_PUSH_LOG_DIR = DATA_DIR / "logs" / "ota_push_jobs"
_DEVICE_IP_REFRESH_INTERVAL_SECONDS = max(60.0, float(os.environ.get("DEVICE_IP_REFRESH_INTERVAL_SECONDS", "1800")))
_device_ip_refresh_lock = threading.Lock()
_device_ip_refresh_thread: threading.Thread | None = None
_device_ip_refresh_request_thread: threading.Thread | None = None
_device_ip_refresh_stop = threading.Event()
_device_ip_refresh_last_run = 0.0
_BUILTIN_ICON_CATALOG: list[dict[str, str]] = [
    {"key": "auto", "label": "Auto", "kind": "builtin"},
    {"key": "power", "label": "Power", "kind": "builtin"},
    {"key": "light", "label": "Light", "kind": "builtin"},
    {"key": "switch", "label": "Switch", "kind": "builtin"},
    {"key": "fan", "label": "Fan", "kind": "builtin"},
    {"key": "lamp", "label": "Lamp", "kind": "builtin"},
    {"key": "strip", "label": "Strip", "kind": "builtin"},
    {"key": "scene", "label": "Scene", "kind": "builtin"},
    {"key": "timer", "label": "Timer", "kind": "builtin"},
    {"key": "home", "label": "Home", "kind": "builtin"},
    {"key": "garage", "label": "Garage", "kind": "builtin"},
    {"key": "gate", "label": "Gate", "kind": "builtin"},
    {"key": "water", "label": "Water", "kind": "builtin"},
    {"key": "pool", "label": "Pool", "kind": "builtin"},
    {"key": "speaker", "label": "Speaker", "kind": "builtin"},
    {"key": "tv", "label": "TV", "kind": "builtin"},
    {"key": "music", "label": "Music", "kind": "builtin"},
    {"key": "heater", "label": "Heater", "kind": "builtin"},
    {"key": "camera", "label": "Camera", "kind": "builtin"},
    {"key": "security", "label": "Security", "kind": "builtin"},
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount("/ui", StaticFiles(directory=STATIC_DIR), name="ui")
if CONTROLLER_WEB_DIR.exists():
    app.mount("/controller", StaticFiles(directory=CONTROLLER_WEB_DIR, html=True), name="controller_ui")
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

    header_session = (
        request.headers.get("x-8bb-session-id", "")
        or request.headers.get("x-client-session-id", "")
    ).strip()
    cookie_session = request.cookies.get(SESSION_COOKIE_NAME, "")
    incoming_session = header_session or cookie_session
    session_id, created = get_or_create_client_session_id(incoming_session)
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

    # Browser UI uses cookie-based stickiness. Controller app uses explicit header session IDs.
    if created and not header_session:
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
    _start_device_ip_refresh_worker()


@app.on_event("shutdown")
def on_shutdown() -> None:
    _device_ip_refresh_stop.set()


def _normalize_mac(value: Any) -> str:
    raw = str(value or "").strip().lower().replace("-", ":")
    if not raw:
        return ""
    parts = raw.split(":")
    if len(parts) != 6:
        return ""
    try:
        normalized = ":".join(f"{int(part, 16):02x}" for part in parts)
    except ValueError:
        return ""
    if normalized == "00:00:00:00:00:00":
        return ""
    return normalized


def _is_ipv4_host(value: Any) -> bool:
    raw = str(value or "").strip()
    if not raw:
        return False
    try:
        return isinstance(ipaddress.ip_address(raw), ipaddress.IPv4Address)
    except ValueError:
        return False


def _subnet_search_hints(*values: Any) -> list[str]:
    hints: list[str] = []
    seen: set[str] = set()
    for value in values:
        raw = str(value or "").strip()
        if not raw:
            continue
        candidates = [raw]
        if _is_ipv4_host(raw):
            parts = raw.split(".")
            if len(parts) == 4:
                candidates.append(".".join(parts[:3]))
        for candidate in candidates:
            normalized = candidate.strip()
            if not normalized or normalized in seen:
                continue
            seen.add(normalized)
            hints.append(normalized)
    return hints


def _find_ip_for_mac(mac: str, subnet_hint: str = "", fallback_host: str = "") -> tuple[str, int]:
    target = _normalize_mac(mac)
    if not target:
        return "", 0

    scan_count = 0
    for hint in _subnet_search_hints(subnet_hint, fallback_host):
        rows = scan_network(subnet_hint=hint, resolve_hostnames=False, automation_only=False)
        scan_count += len(rows)
        for row in rows:
            row_mac = _normalize_mac(row.get("mac"))
            row_ip = str(row.get("ip", "")).strip()
            if row_mac == target and _is_ipv4_host(row_ip):
                return row_ip, scan_count

    # Fallback to ARP/neighbor table without subnet filter.
    if _subnet_search_hints(subnet_hint, fallback_host):
        rows = scan_network(subnet_hint=None, resolve_hostnames=False, automation_only=False)
        scan_count += len(rows)
        for row in rows:
            row_mac = _normalize_mac(row.get("mac"))
            row_ip = str(row.get("ip", "")).strip()
            if row_mac == target and _is_ipv4_host(row_ip):
                return row_ip, scan_count
    return "", scan_count


def _find_mac_for_host(host: str, subnet_hint: str = "") -> tuple[str, int]:
    target_host = str(host or "").strip()
    if not _is_ipv4_host(target_host):
        return "", 0

    scan_count = 0
    primary_hint = str(subnet_hint or "").strip() or target_host
    rows = scan_network(subnet_hint=primary_hint, resolve_hostnames=False, automation_only=False)
    scan_count += len(rows)
    for row in rows:
        row_ip = str(row.get("ip", "")).strip()
        row_mac = _normalize_mac(row.get("mac"))
        if row_ip == target_host and row_mac:
            return row_mac, scan_count

    rows = scan_network(subnet_hint=None, resolve_hostnames=False, automation_only=False)
    scan_count += len(rows)
    for row in rows:
        row_ip = str(row.get("ip", "")).strip()
        row_mac = _normalize_mac(row.get("mac"))
        if row_ip == target_host and row_mac:
            return row_mac, scan_count
    return "", scan_count


def _refresh_single_device_ip_by_mac(device_id: str, mac: str, old_host: str = "", subnet_hint: str = "") -> dict[str, Any]:
    device_mac = _normalize_mac(mac)
    if not device_mac:
        return {"ok": False, "updated": False, "error": "missing_mac"}

    if not subnet_hint:
        try:
            scan_cfg = get_setting("scan")
            subnet_hint = str(scan_cfg.get("subnet_hint", "")).strip() if isinstance(scan_cfg, dict) else ""
        except Exception:
            subnet_hint = ""

    search_hints = _subnet_search_hints(subnet_hint, old_host)
    new_ip, scanned_neighbors = _find_ip_for_mac(device_mac, subnet_hint=subnet_hint, fallback_host=old_host)
    if not new_ip:
        return {
            "ok": False,
            "updated": False,
            "error": "mac_not_found_on_lan",
            "mac": device_mac,
            "old_host": old_host,
            "subnet_hint": subnet_hint,
            "search_hints": search_hints,
            "scanned_neighbors": scanned_neighbors,
        }

    updated = False
    if old_host != new_ip:
        now = utc_now()
        conn = get_connection()
        conn.execute("UPDATE devices SET host=?, updated_at=? WHERE id=?", (new_ip, now, device_id))
        conn.commit()
        conn.close()
        _dashboard_device_cache.pop(device_id, None)
        updated = True
    return {
        "ok": True,
        "updated": updated,
        "mac": device_mac,
        "old_host": old_host,
        "new_host": new_ip,
        "subnet_hint": subnet_hint,
        "search_hints": search_hints,
        "scanned_neighbors": scanned_neighbors,
    }


def _refresh_device_ips_by_mac(*, reason: str, force: bool = False) -> dict[str, Any]:
    global _device_ip_refresh_last_run
    now_mono = time.monotonic()
    if not force and (now_mono - _device_ip_refresh_last_run) < _DEVICE_IP_REFRESH_INTERVAL_SECONDS:
        return {"ok": True, "skipped": True, "reason": "interval_not_elapsed"}
    if not _device_ip_refresh_lock.acquire(blocking=False):
        return {"ok": True, "skipped": True, "reason": "refresh_in_progress"}

    started_at = utc_now()
    try:
        subnet_hint = ""
        try:
            scan_cfg = get_setting("scan")
            subnet_hint = str(scan_cfg.get("subnet_hint", "")).strip() if isinstance(scan_cfg, dict) else ""
        except Exception:
            subnet_hint = ""

        rows = scan_network(subnet_hint=subnet_hint or None, resolve_hostnames=False, automation_only=False)
        mac_to_ip: dict[str, str] = {}
        for row in rows:
            mac = _normalize_mac(row.get("mac"))
            ip = str(row.get("ip", "")).strip()
            if mac and _is_ipv4_host(ip):
                mac_to_ip[mac] = ip

        conn = get_connection()
        devices = conn.execute(
            "SELECT id, name, host, mac FROM devices WHERE mac IS NOT NULL AND TRIM(mac) != ''"
        ).fetchall()
        checked_devices = len(devices)
        updates: list[dict[str, str]] = []
        now = utc_now()
        for device in devices:
            device_mac = _normalize_mac(device["mac"])
            if not device_mac:
                continue
            new_ip = mac_to_ip.get(device_mac, "")
            if not new_ip:
                continue
            old_host = str(device["host"] or "").strip()
            if old_host == new_ip:
                continue
            if old_host and not _is_ipv4_host(old_host):
                continue
            conn.execute(
                "UPDATE devices SET host=?, updated_at=? WHERE id=?",
                (new_ip, now, device["id"]),
            )
            updates.append(
                {
                    "id": str(device["id"]),
                    "name": str(device["name"] or ""),
                    "mac": device_mac,
                    "old_host": old_host,
                    "new_host": new_ip,
                }
            )
        if updates:
            conn.commit()
        conn.close()

        result = {
            "ok": True,
            "reason": reason,
            "started_at": started_at,
            "finished_at": utc_now(),
            "subnet_hint": subnet_hint,
            "neighbors": len(rows),
            "mac_candidates": len(mac_to_ip),
            "devices_checked": checked_devices,
            "updated": len(updates),
        }
        if updates:
            result["changes"] = updates
        append_event("device_ip_refresh", result)
        _device_ip_refresh_last_run = time.monotonic()
        return result
    except Exception as exc:
        error_payload = {
            "ok": False,
            "reason": reason,
            "started_at": started_at,
            "finished_at": utc_now(),
            "error": str(exc),
        }
        append_event("device_ip_refresh_error", error_payload)
        # Retry sooner after errors instead of waiting the full interval.
        _device_ip_refresh_last_run = max(
            0.0,
            time.monotonic() - (_DEVICE_IP_REFRESH_INTERVAL_SECONDS - 60.0),
        )
        return error_payload
    finally:
        _device_ip_refresh_lock.release()


def _request_device_ip_refresh(*, reason: str, force: bool = False) -> dict[str, Any]:
    global _device_ip_refresh_request_thread
    now_mono = time.monotonic()
    if not force and (now_mono - _device_ip_refresh_last_run) < _DEVICE_IP_REFRESH_INTERVAL_SECONDS:
        return {"ok": True, "scheduled": False, "reason": "interval_not_elapsed"}
    thread = _device_ip_refresh_request_thread
    if thread and thread.is_alive():
        return {"ok": True, "scheduled": False, "reason": "refresh_request_in_progress"}

    def runner() -> None:
        try:
            _refresh_device_ips_by_mac(reason=reason, force=force)
        finally:
            pass

    worker = threading.Thread(
        target=runner,
        name=f"device-ip-refresh-request-{reason}",
        daemon=True,
    )
    _device_ip_refresh_request_thread = worker
    worker.start()
    return {"ok": True, "scheduled": True, "reason": reason}


def _device_ip_refresh_loop() -> None:
    _refresh_device_ips_by_mac(reason="startup", force=True)
    while not _device_ip_refresh_stop.wait(_DEVICE_IP_REFRESH_INTERVAL_SECONDS):
        _refresh_device_ips_by_mac(reason="interval", force=True)


def _start_device_ip_refresh_worker() -> None:
    global _device_ip_refresh_thread
    if _device_ip_refresh_thread and _device_ip_refresh_thread.is_alive():
        return
    _device_ip_refresh_stop.clear()
    _device_ip_refresh_thread = threading.Thread(
        target=_device_ip_refresh_loop,
        name="device-ip-refresh-worker",
        daemon=True,
    )
    _device_ip_refresh_thread.start()


@app.get("/")
def web_root() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/favicon.ico", include_in_schema=False)
def favicon() -> Response:
    icon = STATIC_DIR / "favicon.ico"
    if icon.exists():
        return FileResponse(icon)
    return Response(status_code=204)


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


def _is_loopback_or_unspecified_host(host: str) -> bool:
    value = (host or "").strip().lower()
    if not value:
        return True
    if value in ("localhost", "0.0.0.0", "::", "::1"):
        return True
    try:
        ip = ipaddress.ip_address(value)
        return ip.is_loopback or ip.is_unspecified
    except ValueError:
        return False


def _guess_lan_ip() -> str:
    # Best effort: asks OS which source IP would be used for outbound traffic.
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            ip = str(s.getsockname()[0]).strip()
            if ip and not _is_loopback_or_unspecified_host(ip):
                return ip
    except Exception:
        pass
    try:
        _, _, addrs = socket.gethostbyname_ex(socket.gethostname())
        for ip in addrs:
            ip = str(ip).strip()
            if ip and not _is_loopback_or_unspecified_host(ip):
                return ip
    except Exception:
        pass
    return ""


def _resolve_download_base_url(request: Request) -> str:
    explicit = (
        os.environ.get("OTA_PUBLIC_BASE_URL", "").strip()
        or os.environ.get("DOWNLOAD_BASE_URL", "").strip()
        or os.environ.get("PUBLIC_BASE_URL", "").strip()
    )
    if explicit:
        return explicit.rstrip("/")

    base = str(request.base_url).rstrip("/")
    parsed = urlparse(base)
    host = (parsed.hostname or "").strip()
    if not _is_loopback_or_unspecified_host(host):
        return base

    lan_ip = _guess_lan_ip()
    if not lan_ip:
        return base

    # Keep original scheme/port but replace host with LAN-reachable IP.
    port = f":{parsed.port}" if parsed.port else ""
    netloc = f"{lan_ip}{port}"
    replaced = parsed._replace(netloc=netloc)
    return urlunparse(replaced).rstrip("/")


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


def _device_capabilities(row: Any, status: dict[str, Any] | None = None) -> dict[str, Any]:
    device_type = str((status or {}).get("device_type") or row["type"] or "").strip().lower()
    outputs = (status or {}).get("outputs", {})
    if not isinstance(outputs, dict):
        outputs = {}
    metadata = _parse_metadata(row)
    provider = str(metadata.get("provider", "")).strip().lower()

    def is_explicit_relay_key(value: Any) -> bool:
        text = str(value or "").strip().lower()
        return bool(re.match(r"^(relay|switch|channel|out|gang)[_-]?\d+$", text) or re.match(r"^dp_\d+$", text))

    has_relays = device_type == "relay_switch" or any(is_explicit_relay_key(k) for k in outputs.keys())
    relay_channels = sorted(
        [str(k) for k in outputs.keys() if is_explicit_relay_key(k)],
        key=lambda item: (int(re.sub(r"\D+", "", item) or "999"), item),
    )
    supports_light = device_type.startswith("light") or any(k in outputs for k in ("dimmer", "rgb_r", "rgb", "rgbw"))
    supports_rgb = device_type in ("light_rgb", "light_rgbw") or any(k in outputs for k in ("rgb_r", "rgb_g", "rgb_b", "rgb_w"))
    supports_dimmer = device_type in ("light_dimmer", "light_rgb", "light_rgbw") or "dimmer" in outputs
    supports_fan = device_type == "fan" or any(k in outputs for k in ("fan", "fan_power", "fan_speed"))
    supports_scenes = supports_rgb or provider == "moes_bhubw"
    return {
        "supports_relays": has_relays,
        "relay_channels": relay_channels,
        "supports_light": supports_light,
        "supports_rgb": supports_rgb,
        "supports_dimmer": supports_dimmer,
        "supports_fan": supports_fan,
        "supports_scenes": supports_scenes,
        "supports_automation": True,
        "supports_timers": True,
    }


def _list_custom_icons() -> list[dict[str, str]]:
    icons_cfg = get_setting("icons")
    if not isinstance(icons_cfg, dict) or not bool(icons_cfg.get("allow_custom_icons", True)):
        return []
    folder = Path(str(icons_cfg.get("custom_icon_folder", "")).strip())
    if not folder.exists() or not folder.is_dir():
        return []
    items: list[dict[str, str]] = []
    for path in sorted(folder.iterdir()):
        if not path.is_file():
            continue
        if path.suffix.lower() not in (".png", ".jpg", ".jpeg", ".svg", ".webp"):
            continue
        items.append(
            {
                "key": f"custom:{path.stem}",
                "label": path.stem,
                "kind": "custom",
                "path": str(path.resolve()),
            }
        )
    return items


def _list_icon_catalog() -> dict[str, Any]:
    custom_icons = _list_custom_icons()
    icons_cfg = get_setting("icons")
    return {
        "builtin": list(_BUILTIN_ICON_CATALOG),
        "custom": custom_icons,
        "config": icons_cfg if isinstance(icons_cfg, dict) else {},
    }


def _automation_rule_to_dict(row: Any) -> dict[str, Any]:
    try:
        schedule = json.loads(row["schedule_json"] or "{}")
    except Exception:
        schedule = {}
    try:
        payload = json.loads(row["payload_json"] or "{}")
    except Exception:
        payload = {}
    return {
        "id": row["id"],
        "target_type": row["target_type"],
        "target_id": row["target_id"],
        "device_id": row["device_id"],
        "channel_key": row["channel_key"],
        "rule_kind": row["rule_kind"],
        "label": row["label"],
        "enabled": bool(row["enabled"]),
        "schedule": schedule,
        "payload": payload,
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _load_automation_rules_for_target(target_type: str, target_id: str) -> list[dict[str, Any]]:
    conn = get_connection()
    rows = conn.execute(
        """
        SELECT * FROM automation_rules
        WHERE target_type=? AND target_id=?
        ORDER BY rule_kind ASC, updated_at DESC
        """,
        (target_type, target_id),
    ).fetchall()
    conn.close()
    return [_automation_rule_to_dict(row) for row in rows]


def _save_automation_rules_for_target(
    *,
    target_type: str,
    target_id: str,
    rules: list[dict[str, Any]],
    default_device_id: str = "",
    default_channel_key: str = "",
) -> list[dict[str, Any]]:
    conn = get_connection()
    existing_ids = {
        str(row["id"])
        for row in conn.execute(
            "SELECT id FROM automation_rules WHERE target_type=? AND target_id=?",
            (target_type, target_id),
        ).fetchall()
    }
    kept_ids: set[str] = set()
    now = utc_now()
    for item in rules:
        if not isinstance(item, dict):
            continue
        rule_id = str(item.get("id", "")).strip() or str(uuid.uuid4())
        kept_ids.add(rule_id)
        enabled = 1 if bool(item.get("enabled", True)) else 0
        conn.execute(
            """
            INSERT INTO automation_rules(
                id, target_type, target_id, device_id, channel_key, rule_kind, label, enabled,
                schedule_json, payload_json, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                target_type=excluded.target_type,
                target_id=excluded.target_id,
                device_id=excluded.device_id,
                channel_key=excluded.channel_key,
                rule_kind=excluded.rule_kind,
                label=excluded.label,
                enabled=excluded.enabled,
                schedule_json=excluded.schedule_json,
                payload_json=excluded.payload_json,
                updated_at=excluded.updated_at
            """,
            (
                rule_id,
                target_type,
                target_id,
                str(item.get("device_id", default_device_id)).strip(),
                str(item.get("channel_key", default_channel_key)).strip(),
                str(item.get("rule_kind", "automation")).strip() or "automation",
                str(item.get("label", "")).strip(),
                enabled,
                json.dumps(item.get("schedule", {})),
                json.dumps(item.get("payload", {})),
                now,
                now,
            ),
        )
    for stale_id in existing_ids - kept_ids:
        conn.execute("DELETE FROM automation_rules WHERE id=?", (stale_id,))
    conn.commit()
    conn.close()
    return _load_automation_rules_for_target(target_type, target_id)


def _resolve_device_status(row: Any, *, quick: bool = False) -> dict[str, Any]:
    metadata = _parse_metadata(row)
    metadata.setdefault("device_type", str(row["type"] or "").strip())
    host = str(row["host"] or "").strip()
    device_mac = _normalize_mac(row["mac"])
    device_name = str(row["name"] or "").strip()
    if host:
        metadata.setdefault("host", host)
        metadata.setdefault("ip", host)
        metadata.setdefault("tuya_ip", host)
    if device_mac:
        metadata.setdefault("mac", device_mac)
    if device_name:
        metadata.setdefault("name", device_name)
        metadata.setdefault("device_name", device_name)
    provider = str(metadata.get("provider", "")).strip().lower()
    if provider == "moes_bhubw":
        out = get_bhubw_light_status(metadata, quick=quick)
        out.setdefault("source_name", metadata.get("source_name", "MOES BHUB-W"))
        out.setdefault("capabilities", _device_capabilities(row, out))
        return out
    if provider in ("tuya_local", "tuya_cloud", "tuya"):
        out = get_tuya_device_status(metadata, quick=quick)
        if provider == "tuya_cloud":
            out.setdefault("source_name", metadata.get("source_name", "Tuya Cloud"))
        else:
            out.setdefault("source_name", metadata.get("source_name", "Tuya Local"))
        out.setdefault("capabilities", _device_capabilities(row, out))
        return out

    host = str(row["host"] or "").strip()
    if not host:
        raise ValueError("Device host is not set")
    status = fetch_device_status(host, timeout=1.2 if quick else 8.0)
    if isinstance(status, dict) and "device_type" not in status:
        status["device_type"] = row["type"]
    if isinstance(status, dict):
        status.setdefault("provider", "esp_firmware")
        status.setdefault("mode", "local_lan")
        status.setdefault("source_name", metadata.get("source_name", "8bb Firmware"))
        status.setdefault("capabilities", _device_capabilities(row, status))
    return status


def _dashboard_cached_device_status(row: Any, *, quick: bool = True) -> dict[str, Any]:
    device_id = str(row["id"])
    now = time.time()
    cached = _dashboard_device_cache.get(device_id)
    if cached:
        age = max(0.0, now - float(cached.get("ts", 0.0)))
        if age <= _DASHBOARD_DEVICE_CACHE_TTL_SECONDS:
            payload = dict(cached.get("data") or {})
            payload["cached"] = True
            payload["cache_age_s"] = round(age, 2)
            return payload

    try:
        payload = _resolve_device_status(row, quick=quick)
        _dashboard_device_cache[device_id] = {"ts": now, "data": dict(payload)}
        return payload
    except Exception as exc:
        if quick:
            try:
                payload = _resolve_device_status(row, quick=False)
                payload["quick_fallback"] = True
                payload["quick_error"] = str(exc)
                _dashboard_device_cache[device_id] = {"ts": now, "data": dict(payload)}
                append_event(
                    "dashboard_status_quick_retry",
                    {
                        "device_id": device_id,
                        "device_name": str(row["name"] or ""),
                        "provider": str(_parse_metadata(row).get("provider", "")).strip().lower(),
                        "quick_error": str(exc),
                    },
                )
                return payload
            except Exception as retry_exc:
                append_event(
                    "dashboard_status_quick_retry_failed",
                    {
                        "device_id": device_id,
                        "device_name": str(row["name"] or ""),
                        "provider": str(_parse_metadata(row).get("provider", "")).strip().lower(),
                        "quick_error": str(exc),
                        "retry_error": str(retry_exc),
                    },
                )
        if cached:
            age = max(0.0, now - float(cached.get("ts", 0.0)))
            payload = dict(cached.get("data") or {})
            payload["stale"] = True
            payload["cache_age_s"] = round(age, 2)
            return payload
        raise


def _guess_output_bool(outputs: dict[str, Any], channel: str) -> bool | None:
    candidates = [str(channel or "").strip(), "power", "light"]
    for key in candidates:
        if not key:
            continue
        current = _coerce_bool_state(outputs.get(key))
        if current is not None:
            return current
    return None


def _apply_dashboard_command_cache(device_id: str, row: Any, command: dict[str, Any]) -> None:
    state = str(command.get("state", "")).strip().lower()
    channel = str(command.get("channel", "")).strip() or "power"
    target = _coerce_bool_state(state)

    cached = _dashboard_device_cache.get(device_id)
    payload = dict(cached.get("data") or {}) if cached else {}
    outputs = dict(payload.get("outputs") or {})

    if state == "toggle":
        current = _guess_output_bool(outputs, channel)
        if current is not None:
            target = not current

    if target is None:
        _dashboard_device_cache.pop(device_id, None)
        return

    outputs[channel] = target
    channel_lower = channel.lower()
    if channel_lower in {"power", "light"}:
        outputs["power"] = target
        outputs["light"] = target
    elif (
        channel_lower.startswith("relay")
        or channel_lower.startswith("switch")
        or channel_lower.startswith("dp_")
        or channel_lower.startswith("channel")
        or channel_lower.startswith("out")
        or channel_lower.startswith("gang")
    ):
        if "power" in outputs:
            outputs["power"] = target
        if "light" in outputs:
            outputs["light"] = target

    payload["ok"] = True
    payload["outputs"] = outputs
    payload["cached"] = False
    payload["cache_age_s"] = 0.0
    payload["last_command_state"] = state
    payload["last_command_channel"] = channel
    payload.setdefault("provider", str(_parse_metadata(row).get("provider", "")).strip().lower())
    payload.setdefault("device_type", row["type"])
    _dashboard_device_cache[device_id] = {"ts": time.time(), "data": payload}


def _coerce_bool_state(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    text = str(value or "").strip().lower()
    if text in {"on", "true", "1", "yes"}:
        return True
    if text in {"off", "false", "0", "no"}:
        return False
    return None


def _group_member_channel_value(status: dict[str, Any], channel: str) -> Any:
    outputs = status.get("outputs", {})
    if not isinstance(outputs, dict):
        outputs = {}
    channel_key = str(channel or "").strip()
    if channel_key and channel_key in outputs:
        return outputs[channel_key]
    for fallback in ("power", "light", "relay1"):
        if fallback in outputs:
            return outputs[fallback]
    for _, value in outputs.items():
        return value
    return None


def _display_groups() -> list[dict[str, Any]]:
    display = get_setting("display")
    rows = display.get("groups", []) if isinstance(display, dict) else []
    return [item for item in rows if isinstance(item, dict)]


def _group_members_from_source(payload: dict[str, Any]) -> tuple[str, str, list[dict[str, Any]]]:
    group_id = str(payload.get("group_id", "")).strip()
    payload_members = payload.get("members", [])
    payload_kind = str(payload.get("group_kind", "mixed")).strip().lower() or "mixed"
    if group_id:
        for group in _display_groups():
            if str(group.get("id", "")).strip() != group_id:
                continue
            members = [item for item in (group.get("members", []) if isinstance(group.get("members", []), list) else []) if isinstance(item, dict)]
            kind = str(group.get("kind", payload_kind)).strip().lower() or payload_kind
            name = str(group.get("name", payload.get("group_name", ""))).strip()
            return kind, name, members
    members = [item for item in payload_members if isinstance(item, dict)] if isinstance(payload_members, list) else []
    name = str(payload.get("group_name", "")).strip()
    return payload_kind, name, members


def _group_supports_light(members: list[dict[str, Any]], group_kind: str) -> bool:
    if group_kind == "light":
        return True
    for member in members:
        blob = " ".join(
            str(member.get(key, "")).strip().lower()
            for key in ("kind", "channel", "label", "channel_name")
        )
        if any(token in blob for token in ("light", "rgb", "dimmer", "bulb", "lamp")):
            return True
    return False


def _group_supports_fan(members: list[dict[str, Any]], group_kind: str) -> bool:
    if group_kind == "fan":
        return True
    for member in members:
        blob = " ".join(
            str(member.get(key, "")).strip().lower()
            for key in ("kind", "channel", "label", "channel_name")
        )
        if "fan" in blob:
            return True
    return False


def _execute_group_members_action(
    *,
    requested_state: str,
    members: list[dict[str, Any]],
    device_rows: dict[str, Any],
) -> tuple[list[dict[str, Any]], int, int]:
    results: list[dict[str, Any]] = []
    ok_count = 0
    error_count = 0
    for member in members:
        device_id = str(member.get("device_id", "")).strip()
        channel = str(member.get("channel", "")).strip() or "power"
        label = str(member.get("label", "")).strip() or str(member.get("device_name", "")).strip() or device_id
        row = device_rows.get(device_id)
        if not row:
            error_count += 1
            results.append({"device_id": device_id, "channel": channel, "label": label, "ok": False, "error": "Device not found"})
            continue
        try:
            command_payload = {
                "channel": channel,
                "state": requested_state,
                "payload": member.get("command_payload", {}) if isinstance(member.get("command_payload"), dict) else {},
            }
            result = _execute_device_command_by_row(device_id, row, command_payload)
            _apply_dashboard_command_cache(device_id, row, command_payload)
            ok_count += 1
            results.append({"device_id": device_id, "channel": channel, "label": label, "ok": True, "result": result})
        except Exception as exc:
            error_count += 1
            results.append({"device_id": device_id, "channel": channel, "label": label, "ok": False, "error": str(exc)})
    return results, ok_count, error_count


def _resolve_group_tile_data(payload: dict[str, Any], device_map: dict[str, Any]) -> dict[str, Any]:
    group_kind, group_name, members_raw = _group_members_from_source(payload)
    members: list[dict[str, Any]] = []
    on_count = 0
    off_count = 0
    unknown_count = 0
    cloud_count = 0

    for item in members_raw if isinstance(members_raw, list) else []:
        if not isinstance(item, dict):
            continue
        device_id = str(item.get("device_id", "")).strip()
        channel = str(item.get("channel", "")).strip()
        device_row = device_map.get(device_id)
        if not device_row:
            members.append(
                {
                    "device_id": device_id,
                    "channel": channel,
                    "name": str(item.get("label", "")).strip() or "Missing device",
                    "ok": False,
                    "error": "Device not found",
                }
            )
            unknown_count += 1
            continue
        try:
            status = _dashboard_cached_device_status(device_row, quick=True)
            provider = str(status.get("provider", "")).strip().lower()
            member_value = _group_member_channel_value(status, channel)
            member_state = _coerce_bool_state(member_value)
            if provider == "tuya_cloud" or str(status.get("mode", "")).strip().lower().find("cloud") >= 0:
                cloud_count += 1
            if member_state is True:
                on_count += 1
            elif member_state is False:
                off_count += 1
            else:
                unknown_count += 1
            members.append(
                {
                    "device_id": device_id,
                    "channel": channel,
                    "name": str(item.get("label", "")).strip() or str(item.get("device_name", "")).strip() or str(device_row["name"] or "").strip(),
                    "device_name": str(device_row["name"] or "").strip(),
                    "value": member_value,
                    "state": member_state,
                    "provider": provider,
                    "mode": str(status.get("mode", "")).strip(),
                    "ok": True,
                }
            )
        except Exception as exc:
            members.append(
                {
                    "device_id": device_id,
                    "channel": channel,
                    "name": str(item.get("label", "")).strip() or str(item.get("device_name", "")).strip() or str(device_row["name"] or "").strip(),
                    "ok": False,
                    "error": str(exc),
                }
            )
            unknown_count += 1

    member_count = len(members)
    aggregate_state = "unknown"
    power_value: Any = None
    if member_count > 0 and on_count == member_count:
        aggregate_state = "on"
        power_value = True
    elif member_count > 0 and off_count == member_count:
        aggregate_state = "off"
        power_value = False
    elif on_count > 0 and off_count > 0:
        aggregate_state = "mixed"
        power_value = "mixed"
    elif on_count > 0 and unknown_count > 0:
        aggregate_state = "mixed"
        power_value = "mixed"
    elif off_count > 0 and unknown_count > 0:
        aggregate_state = "mixed"
        power_value = "mixed"

    mode = "local_lan"
    if cloud_count > 0 and cloud_count == member_count:
        mode = "cloud"
    elif cloud_count > 0:
        mode = "hybrid"

    supports_light = _group_supports_light(members_raw, group_kind)
    supports_fan = _group_supports_fan(members_raw, group_kind)
    return {
        "provider": "group",
        "mode": mode,
        "device_type": f"group_{group_kind}",
        "group_kind": group_kind,
        "group_name": group_name,
        "member_count": member_count,
        "on_count": on_count,
        "off_count": off_count,
        "unknown_count": unknown_count,
        "cloud_count": cloud_count,
        "group_state": aggregate_state,
        "outputs": {
            "power": power_value,
            "light": power_value if supports_light else None,
        },
        "members": members,
        "capabilities": {
            "supports_automation": True,
            "supports_group": True,
            "supports_light": supports_light,
            "supports_rgb": False,
            "supports_fan": supports_fan,
            "supports_scenes": supports_light,
            "supports_timers": True,
        },
        "source_name": "8bb Groups",
    }


def _resolve_automation_tile_data(payload: dict[str, Any], device_map: dict[str, Any]) -> dict[str, Any]:
    action = str(payload.get("action", "group")).strip().lower() or "group"
    requested_state = str(payload.get("state", "toggle")).strip().lower() or "toggle"
    group_kind, group_name, members = _group_members_from_source(payload)
    supports_light = _group_supports_light(members, group_kind)
    supports_fan = _group_supports_fan(members, group_kind)
    if action != "group":
        return {
            "provider": "automation",
            "mode": "manual",
            "device_type": "automation",
            "action": action,
            "group_kind": group_kind,
            "group_name": group_name,
            "requested_state": requested_state,
            "member_count": len(members),
            "capabilities": {
                "supports_automation": True,
                "supports_group": False,
                "supports_light": supports_light,
                "supports_rgb": False,
                "supports_fan": supports_fan,
                "supports_scenes": supports_light,
                "supports_timers": True,
            },
            "source_name": "8bb Automation",
        }
    group_data = _resolve_group_tile_data(payload, device_map)
    return {
        **group_data,
        "provider": "automation",
        "device_type": "automation",
        "action": action,
        "requested_state": requested_state,
        "source_name": "8bb Automation",
    }


def _execute_device_command_by_row(
    device_id: str,
    row: Any,
    payload: dict[str, Any],
    *,
    _visited_channels: set[str] | None = None,
) -> dict[str, Any]:
    channel = str(payload.get("channel", "")).strip()
    state = str(payload.get("state", "")).strip() or None
    value = payload.get("value")
    payload_obj = payload.get("payload", {})
    if not isinstance(payload_obj, dict):
        payload_obj = {}

    conn = get_connection()
    channel_row = conn.execute(
        "SELECT payload_json FROM device_channels WHERE device_id=? AND channel_key=?",
        (device_id, channel),
    ).fetchone()
    conn.close()

    cmd = {
        "channel": channel,
        "state": state,
        "value": value,
        "payload": dict(payload_obj),
    }
    if channel_row:
        try:
            channel_payload = json.loads(channel_row["payload_json"])
        except Exception:
            channel_payload = {}
        if isinstance(channel_payload, dict):
            cmd["payload"] = {**channel_payload, **cmd["payload"]}

    visited = set(_visited_channels or set())
    if channel:
        if channel in visited:
            raise ValueError(f"Combined channel loop detected at '{channel}'")
        visited.add(channel)

    member_channels = cmd["payload"].get("member_channels", [])
    if isinstance(member_channels, list) and member_channels:
        nested_payload = {
            key: value
            for key, value in cmd["payload"].items()
            if key not in {"member_channels"}
        }
        results: list[dict[str, Any]] = []
        ok_count = 0
        error_count = 0
        for raw_member in member_channels:
            member_channel = str(raw_member or "").strip()
            if not member_channel:
                continue
            try:
                result = _execute_device_command_by_row(
                    device_id,
                    row,
                    {
                        "channel": member_channel,
                        "state": state,
                        "value": value,
                        "payload": dict(nested_payload),
                    },
                    _visited_channels=visited,
                )
                ok_count += 1
                results.append({"channel": member_channel, "ok": True, "result": result})
            except Exception as exc:
                error_count += 1
                results.append({"channel": member_channel, "ok": False, "error": str(exc)})
        return {
            "ok": error_count == 0,
            "provider": "device_group",
            "channel": channel,
            "member_channels": [str(item or "").strip() for item in member_channels if str(item or "").strip()],
            "ok_count": ok_count,
            "error_count": error_count,
            "results": results,
        }

    host = (row["host"] or "").strip()
    device_mac = _normalize_mac(row["mac"])
    passcode = decrypt_secret(row["passcode_enc"] or "")
    metadata = _parse_metadata(row)
    metadata.setdefault("device_type", str(row["type"] or "").strip())
    if host:
        metadata.setdefault("host", host)
        metadata.setdefault("ip", host)
        metadata.setdefault("tuya_ip", host)
    if device_mac:
        metadata.setdefault("mac", device_mac)
    device_name = str(row["name"] or "").strip()
    if device_name:
        metadata.setdefault("name", device_name)
        metadata.setdefault("device_name", device_name)
    provider = str(metadata.get("provider", "")).strip().lower()

    if provider == "moes_bhubw":
        return send_bhubw_light_command(metadata=metadata, command=cmd)
    if provider in ("tuya_local", "tuya_cloud", "tuya"):
        return send_tuya_device_command(metadata=metadata, command=cmd)

    if not host:
        raise ValueError("Device host is not set")
    if not passcode:
        raise ValueError("Device passcode is not configured")

    merged_cmd = dict(cmd)
    merged_cmd.update(cmd["payload"])
    try:
        return send_device_command(host, passcode, merged_cmd)
    except httpx.HTTPError as exc:
        refresh_result = _refresh_single_device_ip_by_mac(device_id, device_mac, old_host=host) if device_mac else {"ok": False}
        retry_host = str(refresh_result.get("new_host", "")).strip()
        if refresh_result.get("ok") and retry_host and retry_host != host:
            return send_device_command(retry_host, passcode, merged_cmd)
        raise exc


def _require_device(device_id: str) -> tuple[Any, Any]:
    conn = get_connection()
    row = conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="Device not found")
    return conn, row


def _persist_device_metadata_patch(device_id: str, row: Any, patch: dict[str, Any] | None) -> None:
    if not isinstance(patch, dict) or not patch:
        return
    metadata = _parse_metadata(row)
    changed = False
    for key, value in patch.items():
        text = str(value or "").strip()
        if not text:
            continue
        if str(metadata.get(key, "")).strip() != text:
            metadata[key] = text
            changed = True
    if not changed:
        return
    now = utc_now()
    conn = get_connection()
    conn.execute(
        "UPDATE devices SET metadata_json=?, updated_at=? WHERE id=?",
        (json.dumps(metadata), now, device_id),
    )
    conn.commit()
    conn.close()


def _slug_value(value: str, fallback: str = "item") -> str:
    raw = re.sub(r"[^a-zA-Z0-9_-]+", "-", (value or "").strip().lower()).strip("-")
    return raw[:64] if raw else fallback


def _profile_push_job_read(job_id: str) -> dict[str, Any] | None:
    with _profile_push_jobs_lock:
        item = _profile_push_jobs.get(job_id)
        if not item:
            return None
        return dict(item)


def _profile_push_job_update(job_id: str, **fields: Any) -> dict[str, Any] | None:
    with _profile_push_jobs_lock:
        item = _profile_push_jobs.get(job_id)
        if not item:
            return None
        item.update(fields)
        return dict(item)


def _profile_push_job_append_output(job_id: str, line: str) -> None:
    now = utc_now()
    message = str(line or "").strip()
    if not message:
        return
    with _profile_push_jobs_lock:
        item = _profile_push_jobs.get(job_id)
        if not item:
            return
        output = str(item.get("output", ""))
        chunk = f"[{now}] {message}"
        item["output"] = f"{output}\n{chunk}".strip() if output else chunk
        log_file = str(item.get("log_file", "")).strip()
    if log_file:
        try:
            log_path = Path(log_file)
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("a", encoding="utf-8") as fp:
                fp.write(chunk + "\n")
        except Exception:
            pass


def _start_profile_push_job(
    *,
    profile_id: str,
    profile_name: str,
    device_id: str,
    host: str,
    firmware_url: str,
    manifest_url: str,
    passcode: str,
    mode: str,
    precheck: dict[str, Any] | None = None,
) -> dict[str, Any]:
    job_id = str(uuid.uuid4())
    created_at = utc_now()
    day = time.strftime("%Y%m%d")
    OTA_PUSH_LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_file = OTA_PUSH_LOG_DIR / f"{day}_{job_id[:8]}.log"
    job = {
        "job_id": job_id,
        "status": "queued",
        "profile_id": profile_id,
        "profile_name": profile_name,
        "device_id": device_id,
        "host": host,
        "mode": mode,
        "firmware_url": firmware_url,
        "manifest_url": manifest_url,
        "created_at": created_at,
        "started_at": "",
        "ended_at": "",
        "error": "",
        "result": {},
        "precheck": precheck or {},
        "log_file": str(log_file),
        "output": "",
    }
    with _profile_push_jobs_lock:
        _profile_push_jobs[job_id] = job

    def _runner() -> None:
        _profile_push_job_update(job_id, status="running", started_at=utc_now())
        if precheck:
            _profile_push_job_append_output(job_id, "Pre-check passed (ping/status/pair).")
        _profile_push_job_append_output(job_id, f"Starting profile OTA push ({mode})")
        _profile_push_job_append_output(job_id, f"host={host}")
        _profile_push_job_append_output(job_id, f"profile={profile_name} ({profile_id})")
        _profile_push_job_append_output(job_id, "Preflight: checking manifest/firmware URLs from server...")
        append_event(
            "firmware_profile_push_started",
            {
                "job_id": job_id,
                "profile_id": profile_id,
                "device_id": device_id,
                "host": host,
                "mode": mode,
            },
        )
        try:
            preflight = _preflight_download_targets(manifest_url, firmware_url)
            _profile_push_job_append_output(job_id, f"Preflight manifest: {json.dumps(preflight.get('manifest', {}))}")
            _profile_push_job_append_output(job_id, f"Preflight firmware: {json.dumps(preflight.get('firmware', {}))}")
            if not preflight.get("ok"):
                raise RuntimeError(f"OTA preflight failed: {preflight.get('error', 'download url check failed')}")

            _profile_push_job_append_output(job_id, "Sending /api/ota/apply to device...")
            wait_step_s = 3
            waited_s = 0
            with ThreadPoolExecutor(max_workers=1) as push_exec:
                future = push_exec.submit(
                    push_ota_to_device,
                    host,
                    passcode,
                    firmware_url,
                    manifest_url,
                    lambda msg: _profile_push_job_append_output(job_id, msg),
                )
                while True:
                    try:
                        result = future.result(timeout=wait_step_s)
                        break
                    except FuturesTimeoutError:
                        waited_s += wait_step_s
                        _profile_push_job_append_output(
                            job_id,
                            f"Waiting for device OTA response... {waited_s}s (device may be downloading/writing image).",
                        )
            _profile_push_job_append_output(job_id, "Device accepted OTA request.")
            _profile_push_job_update(
                job_id,
                status="success",
                ended_at=utc_now(),
                result=result if isinstance(result, dict) else {"raw": str(result)},
            )
            append_event(
                "firmware_profile_push_finished",
                {
                    "job_id": job_id,
                    "profile_id": profile_id,
                    "device_id": device_id,
                    "host": host,
                    "mode": mode,
                    "ok": True,
                },
            )
        except Exception as exc:
            _profile_push_job_append_output(job_id, f"ERROR: {exc}")
            _profile_push_job_update(job_id, status="failed", ended_at=utc_now(), error=str(exc))
            append_event(
                "firmware_profile_push_finished",
                {
                    "job_id": job_id,
                    "profile_id": profile_id,
                    "device_id": device_id,
                    "host": host,
                    "mode": mode,
                    "ok": False,
                    "error": str(exc),
                },
            )

    _profile_push_executor.submit(_runner)
    return dict(job)


def _run_ota_precheck(host: str, passcode: str) -> dict[str, Any]:
    ping = ping_host(host, timeout_ms=1500)
    status = probe_status_quick(host, timeout=2.0)
    pair = test_device_pair(host, passcode)
    ok = bool(ping.get("ok")) and bool(status.get("ok")) and bool(pair.get("ok"))
    return {
        "ok": ok,
        "host": host,
        "ping": ping,
        "status": status,
        "pair": pair,
        "checked_at": utc_now(),
    }


def _preflight_download_targets(manifest_url: str, firmware_url: str) -> dict[str, Any]:
    timeout = httpx.Timeout(connect=4.0, read=10.0, write=10.0, pool=10.0)
    out: dict[str, Any] = {"ok": False, "manifest": {}, "firmware": {}}
    with httpx.Client(timeout=timeout, follow_redirects=True) as client:
        manifest_res = client.get(manifest_url)
        out["manifest"] = {
            "ok": manifest_res.status_code < 400,
            "status_code": manifest_res.status_code,
            "bytes": len(manifest_res.content or b""),
            "content_type": manifest_res.headers.get("content-type", ""),
        }
        if manifest_res.status_code >= 400:
            out["error"] = f"Manifest URL returned HTTP {manifest_res.status_code}"
            return out

        firmware_res = client.get(firmware_url, headers={"Range": "bytes=0-0"})
        out["firmware"] = {
            "ok": firmware_res.status_code < 400,
            "status_code": firmware_res.status_code,
            "content_range": firmware_res.headers.get("content-range", ""),
            "content_length": firmware_res.headers.get("content-length", ""),
            "content_type": firmware_res.headers.get("content-type", ""),
        }
        if firmware_res.status_code >= 400:
            out["error"] = f"Firmware URL returned HTTP {firmware_res.status_code}"
            return out

    out["ok"] = bool(out["manifest"].get("ok")) and bool(out["firmware"].get("ok"))
    return out


def _is_single_ipv4_host_hint(value: str) -> bool:
    raw = str(value or "").strip()
    if not raw or "/" in raw:
        return False
    try:
        return isinstance(ipaddress.ip_address(raw), ipaddress.IPv4Address)
    except ValueError:
        return False


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
    icons = get_setting("icons")
    return {
        "spotify": _decrypt_fields(spotify, ["client_secret", "refresh_token"]),
        "weather": _decrypt_fields(weather, ["api_key"]),
        "tuya": _decrypt_fields(tuya, ["client_secret", "local_key"]),
        "scan": scan,
        "moes": _decrypt_fields(moes, ["hub_local_key"]),
        "ota": _decrypt_fields(ota, ["shared_key"]),
        "icons": icons,
    }


@app.put("/api/config/integrations", dependencies=[Depends(require_auth_if_configured)])
def put_integrations(payload: IntegrationsConfig) -> dict[str, Any]:
    data = payload.model_dump()
    existing_tuya = get_setting("tuya")
    incoming_api_device_id = str(data["tuya"].get("api_device_id", "")).strip()
    if not incoming_api_device_id:
        preserved_api_device_id = str(existing_tuya.get("api_device_id", "")).strip()
        if preserved_api_device_id:
            data["tuya"]["api_device_id"] = preserved_api_device_id

    data["spotify"]["client_secret"] = encrypt_secret(data["spotify"].get("client_secret", ""))
    data["spotify"]["refresh_token"] = encrypt_secret(data["spotify"].get("refresh_token", ""))
    data["weather"]["api_key"] = encrypt_secret(data["weather"].get("api_key", ""))
    data["tuya"]["client_secret"] = encrypt_secret(data["tuya"].get("client_secret", ""))
    data["tuya"]["local_key"] = encrypt_secret(data["tuya"].get("local_key", ""))
    data["moes"]["hub_local_key"] = encrypt_secret(data["moes"].get("hub_local_key", ""))
    data["ota"]["shared_key"] = encrypt_secret(data["ota"].get("shared_key", ""))

    set_setting("spotify", data["spotify"])
    set_setting("weather", data["weather"])
    set_setting("tuya", data["tuya"])
    set_setting("scan", data["scan"])
    set_setting("moes", data["moes"])
    set_setting("ota", data["ota"])
    set_setting("icons", data.get("icons", {}))
    append_event(
        "integrations_updated",
        {
            "scan": data["scan"],
            "icons": data.get("icons", {}),
            "tuya": {
                "cloud_region_present": bool(str(data["tuya"].get("cloud_region", "")).strip()),
                "client_id_present": bool(str(data["tuya"].get("client_id", "")).strip()),
                "client_secret_present": bool(str(data["tuya"].get("client_secret", "")).strip()),
                "api_device_id_present": bool(str(data["tuya"].get("api_device_id", "")).strip()),
            },
        },
    )
    return {"saved": True}


@app.get("/api/icons/catalog")
def get_icon_catalog() -> dict[str, Any]:
    return _list_icon_catalog()


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
    hub_mac = ""
    hub_local_key = ""
    hub_version = ""
    subnet_hint = ""
    if isinstance(payload, dict):
        hub_device_id = str(payload.get("hub_device_id", "")).strip()
        hub_ip = str(payload.get("hub_ip", "")).strip()
        hub_mac = str(payload.get("hub_mac", "")).strip()
        hub_local_key = str(payload.get("hub_local_key", "")).strip()
        hub_version = str(payload.get("hub_version", "")).strip()
        subnet_hint = str(payload.get("subnet_hint", "")).strip()
    try:
        return discover_bhubw_lights(
            hub_device_id=hub_device_id,
            hub_ip=hub_ip,
            hub_mac=hub_mac,
            hub_local_key=hub_local_key,
            hub_version=hub_version,
            subnet_hint=subnet_hint,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/moes/test", dependencies=[Depends(require_auth_if_configured)])
def post_moes_test(payload: dict[str, Any]) -> dict[str, Any]:
    hub_device_id = ""
    hub_ip = ""
    hub_mac = ""
    hub_local_key = ""
    hub_version = ""
    subnet_hint = ""
    if isinstance(payload, dict):
        hub_device_id = str(payload.get("hub_device_id", "")).strip()
        hub_ip = str(payload.get("hub_ip", "")).strip()
        hub_mac = str(payload.get("hub_mac", "")).strip()
        hub_local_key = str(payload.get("hub_local_key", "")).strip()
        hub_version = str(payload.get("hub_version", "")).strip()
        subnet_hint = str(payload.get("subnet_hint", "")).strip()
    try:
        return test_bhubw_connection(
            hub_device_id=hub_device_id,
            hub_ip=hub_ip,
            hub_mac=hub_mac,
            hub_local_key=hub_local_key,
            hub_version=hub_version,
            subnet_hint=subnet_hint,
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
def post_tuya_local_scan(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    subnet_hint = ""
    cloud_region = ""
    client_id = ""
    client_secret = ""
    api_device_id = ""
    if isinstance(payload, dict):
        subnet_hint = str(payload.get("subnet_hint", "")).strip()
        cloud_region = str(payload.get("cloud_region", "")).strip()
        client_id = str(payload.get("client_id", "")).strip()
        client_secret = str(payload.get("client_secret", "")).strip()
        api_device_id = str(payload.get("api_device_id", "")).strip()
    try:
        return tuya_local_scan(
            subnet_hint=subnet_hint,
            cloud_region=cloud_region,
            client_id=client_id,
            client_secret=client_secret,
            api_device_id=api_device_id,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/tuya/cloud-devices", dependencies=[Depends(require_auth_if_configured)])
def post_tuya_cloud_devices(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    cloud_region = ""
    client_id = ""
    client_secret = ""
    api_device_id = ""
    if isinstance(payload, dict):
        cloud_region = str(payload.get("cloud_region", "")).strip()
        client_id = str(payload.get("client_id", "")).strip()
        client_secret = str(payload.get("client_secret", "")).strip()
        api_device_id = str(payload.get("api_device_id", "")).strip()
    try:
        return tuya_cloud_devices(
            cloud_region=cloud_region,
            client_id=client_id,
            client_secret=client_secret,
            api_device_id=api_device_id,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/tuya/test", dependencies=[Depends(require_auth_if_configured)])
def post_tuya_test(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    cloud_region = ""
    client_id = ""
    client_secret = ""
    api_device_id = ""
    if isinstance(payload, dict):
        cloud_region = str(payload.get("cloud_region", "")).strip()
        client_id = str(payload.get("client_id", "")).strip()
        client_secret = str(payload.get("client_secret", "")).strip()
        api_device_id = str(payload.get("api_device_id", "")).strip()
    try:
        return tuya_test_credentials(
            cloud_region=cloud_region,
            client_id=client_id,
            client_secret=client_secret,
            api_device_id=api_device_id,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/integrations/tuya/scan-save", dependencies=[Depends(require_auth_if_configured)])
def post_tuya_scan_save(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    subnet_hint = ""
    cloud_region = ""
    client_id = ""
    client_secret = ""
    api_device_id = ""
    if isinstance(payload, dict):
        subnet_hint = str(payload.get("subnet_hint", "")).strip()
        cloud_region = str(payload.get("cloud_region", "")).strip()
        client_id = str(payload.get("client_id", "")).strip()
        client_secret = str(payload.get("client_secret", "")).strip()
        api_device_id = str(payload.get("api_device_id", "")).strip()
    try:
        return tuya_scan_and_save(
            subnet_hint=subnet_hint,
            cloud_region=cloud_region,
            client_id=client_id,
            client_secret=client_secret,
            api_device_id=api_device_id,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/integrations/tuya/devices-file")
def get_tuya_devices_file() -> dict[str, Any]:
    try:
        return tuya_devices_file()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/devices")
def list_devices() -> list[dict[str, Any]]:
    _request_device_ip_refresh(reason="devices_list", force=False)
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
    host = str(payload.host or "").strip()
    host_value = host or None
    mac = _normalize_mac(payload.mac)
    mac_source = "payload"
    mac_scan_neighbors = 0
    if not mac and _is_ipv4_host(host):
        try:
            scan_cfg = get_setting("scan")
            subnet_hint = str(scan_cfg.get("subnet_hint", "")).strip() if isinstance(scan_cfg, dict) else ""
        except Exception:
            subnet_hint = ""
        found_mac, scanned_neighbors = _find_mac_for_host(host, subnet_hint=subnet_hint)
        mac_scan_neighbors = scanned_neighbors
        if found_mac:
            mac = found_mac
            mac_source = "host_lookup"
        else:
            mac_source = "missing"

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
            host_value,
            mac,
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

    append_event(
        "device_created",
        {
            "id": device_id,
            "name": payload.name,
            "type": payload.type,
            "host": host,
            "mac": mac,
            "mac_source": mac_source,
            "mac_scan_neighbors": mac_scan_neighbors,
        },
    )
    _refresh_device_ips_by_mac(reason="device_added", force=True)
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
    if "mac" in updates:
        current["mac"] = _normalize_mac(updates.pop("mac"))

    for k, v in updates.items():
        current[k] = v
    current["updated_at"] = utc_now()

    conn.execute(
        """
        UPDATE devices
        SET name=?, type=?, host=?, mac=?, passcode_hash=?, passcode_enc=?, ip_mode=?, static_ip=?, gateway=?, subnet_mask=?, metadata_json=?, updated_at=?
        WHERE id=?
        """,
        (
            current["name"],
            current["type"],
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
    removed_tiles = conn.execute("DELETE FROM main_tiles WHERE tile_type='device' AND ref_id=?", (device_id,)).rowcount
    conn.commit()
    conn.close()
    if count == 0:
        raise HTTPException(status_code=404, detail="Device not found")
    append_event("device_removed", {"id": device_id, "removed_tiles": removed_tiles})
    return {"removed": True, "removed_tiles": removed_tiles}


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


@app.post("/api/devices/{device_id}/refresh-ip", dependencies=[Depends(require_auth_if_configured)])
def refresh_device_ip(device_id: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    old_host = str(row["host"] or "").strip()
    device_mac = _normalize_mac(row["mac"])
    if not device_mac:
        conn.close()
        raise HTTPException(status_code=400, detail="Device MAC is not set for this device")

    subnet_hint = ""
    if isinstance(payload, dict):
        subnet_hint = str(payload.get("subnet_hint", "")).strip()
    if not subnet_hint:
        try:
            scan_cfg = get_setting("scan")
            subnet_hint = str(scan_cfg.get("subnet_hint", "")).strip() if isinstance(scan_cfg, dict) else ""
        except Exception:
            subnet_hint = ""
    conn.close()
    result = _refresh_single_device_ip_by_mac(
        device_id,
        device_mac,
        old_host=old_host,
        subnet_hint=subnet_hint,
    )
    if not result.get("ok"):
        append_event(
            "device_ip_refresh_manual",
            {
                "id": device_id,
                "name": str(row["name"] or ""),
                "mac": device_mac,
                "old_host": old_host,
                "updated": False,
                "subnet_hint": subnet_hint,
                "search_hints": result.get("search_hints", []),
                "scanned_neighbors": result.get("scanned_neighbors", 0),
                "error": result.get("error", "mac_not_found_on_lan"),
            },
        )
        searched = ", ".join(str(item) for item in result.get("search_hints", []) if str(item).strip()) or "(none)"
        raise HTTPException(
            status_code=404,
            detail=(
                f"No LAN IP found for MAC {device_mac}. "
                f"Searched hints: {searched}. "
                f"Neighbors seen: {int(result.get('scanned_neighbors', 0))}."
            ),
        )

    conn = get_connection()
    updated_row = conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
    device = _device_to_dict(updated_row, conn)
    conn.close()

    append_event(
        "device_ip_refresh_manual",
        {
            "id": device_id,
            "name": str(row["name"] or ""),
            "mac": device_mac,
            "old_host": old_host,
            "new_host": result.get("new_host", old_host),
            "updated": bool(result.get("updated")),
            "subnet_hint": result.get("subnet_hint", subnet_hint),
            "search_hints": result.get("search_hints", []),
            "scanned_neighbors": result.get("scanned_neighbors", 0),
        },
    )
    return {
        "ok": True,
        "id": device_id,
        "name": str(row["name"] or ""),
        "mac": device_mac,
        "old_host": old_host,
        "new_host": result.get("new_host", old_host),
        "updated": bool(result.get("updated")),
        "subnet_hint": result.get("subnet_hint", subnet_hint),
        "search_hints": result.get("search_hints", []),
        "scanned_neighbors": result.get("scanned_neighbors", 0),
        "device": device,
    }


@app.post("/api/devices/{device_id}/assign-mac", dependencies=[Depends(require_auth_if_configured)])
def assign_device_mac(device_id: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    host = str(row["host"] or "").strip()
    old_mac = _normalize_mac(row["mac"])

    raw_requested_mac = ""
    requested_mac = ""
    lookup_from_host = True
    subnet_hint = ""
    if isinstance(payload, dict):
        raw_requested_mac = str(payload.get("mac", "")).strip()
        requested_mac = _normalize_mac(raw_requested_mac)
        if "lookup_from_host" in payload:
            lookup_from_host = bool(payload.get("lookup_from_host"))
        subnet_hint = str(payload.get("subnet_hint", "")).strip()
    if raw_requested_mac and not requested_mac:
        conn.close()
        raise HTTPException(status_code=400, detail="Invalid MAC format. Use aa:bb:cc:dd:ee:ff")
    if not subnet_hint:
        try:
            scan_cfg = get_setting("scan")
            subnet_hint = str(scan_cfg.get("subnet_hint", "")).strip() if isinstance(scan_cfg, dict) else ""
        except Exception:
            subnet_hint = ""

    scan_neighbors = 0
    assigned_mac = requested_mac
    source = "manual"
    if not assigned_mac and lookup_from_host:
        assigned_mac, scan_neighbors = _find_mac_for_host(host, subnet_hint=subnet_hint)
        source = "host_lookup"

    if not assigned_mac:
        conn.close()
        if not _is_ipv4_host(host):
            raise HTTPException(status_code=400, detail="Device host must be a valid IPv4 address to auto-lookup MAC")
        raise HTTPException(status_code=404, detail=f"No MAC found for host {host}")

    updated = assigned_mac != old_mac
    now = utc_now()
    conn.execute("UPDATE devices SET mac=?, updated_at=? WHERE id=?", (assigned_mac, now, device_id))
    conn.commit()
    updated_row = conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
    device = _device_to_dict(updated_row, conn)
    conn.close()

    append_event(
        "device_mac_assigned",
        {
            "id": device_id,
            "name": str(row["name"] or ""),
            "host": host,
            "old_mac": old_mac,
            "new_mac": assigned_mac,
            "updated": updated,
            "source": source,
            "subnet_hint": subnet_hint,
            "scanned_neighbors": scan_neighbors,
        },
    )
    return {
        "ok": True,
        "id": device_id,
        "name": str(row["name"] or ""),
        "host": host,
        "old_mac": old_mac,
        "new_mac": assigned_mac,
        "updated": updated,
        "source": source,
        "subnet_hint": subnet_hint,
        "scanned_neighbors": scan_neighbors,
        "device": device,
    }


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
    _persist_device_metadata_patch(device_id, row, status.get("metadata_patch") if isinstance(status, dict) else None)
    conn.execute("UPDATE devices SET last_seen_at=?, updated_at=? WHERE id=?", (now, now, device_id))
    conn.commit()
    conn.close()
    return status


@app.post("/api/devices/{device_id}/command", dependencies=[Depends(require_auth_if_configured)])
def post_device_command(device_id: str, payload: DeviceCommandRequest) -> dict[str, Any]:
    conn, row = _require_device(device_id)
    conn.close()
    command = payload.model_dump()
    try:
        result = _execute_device_command_by_row(device_id, row, command)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Device command failed: {exc}") from exc
    except Exception as exc:
        metadata = _parse_metadata(row)
        provider = str(metadata.get("provider", "")).strip().lower()
        detail_prefix = "Tuya command failed" if provider.startswith("tuya") else "MOES local command failed" if provider == "moes_bhubw" else "Device command failed"
        raise HTTPException(status_code=502, detail=f"{detail_prefix}: {exc}") from exc
    _persist_device_metadata_patch(device_id, row, result.get("metadata_patch") if isinstance(result, dict) else None)
    _apply_dashboard_command_cache(device_id, row, command)
    append_event("device_command", {"device_id": device_id, "channel": payload.channel, "state": payload.state, "provider": str(_parse_metadata(row).get('provider', '')).strip().lower()})
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

    base = _resolve_download_base_url(request)
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
    # Main dashboard loads should also opportunistically reconcile DHCP IP changes.
    _request_device_ip_refresh(reason="main_tile_load", force=False)
    conn = get_connection()
    rows = conn.execute("SELECT * FROM main_tiles ORDER BY updated_at DESC").fetchall()
    device_map = {r["id"]: dict(r) for r in conn.execute("SELECT * FROM devices").fetchall()}
    conn.close()

    tiles: list[dict[str, Any]] = []
    orphan_tile_ids: list[str] = []
    pending: dict[Any, int] = {}
    executor = ThreadPoolExecutor(max_workers=max(1, min(8, len(rows))))
    deadline = time.monotonic() + max(1.0, _DASHBOARD_TOTAL_TIMEOUT_SECONDS)

    def resolve_live(row: Any) -> tuple[dict[str, Any], str | None]:
        tile_type = row["tile_type"]
        try:
            if tile_type == "weather":
                return weather_current(timeout_s=2.0), None
            if tile_type == "spotify":
                return spotify_now_playing(timeout_s=2.5), None
            if tile_type == "device":
                if row["ref_id"] not in device_map:
                    return {}, "Device not found"
                dev = device_map[row["ref_id"]]
                data = _dashboard_cached_device_status(dev, quick=True)
                data["device_type"] = dev.get("type")
                return data, None
            if tile_type == "group":
                payload = json.loads(row["payload_json"])
                return _resolve_group_tile_data(payload if isinstance(payload, dict) else {}, device_map), None
            if tile_type == "automation":
                payload = json.loads(row["payload_json"])
                return _resolve_automation_tile_data(payload if isinstance(payload, dict) else {}, device_map), None
            return {}, None
        except Exception as exc:
            return {}, str(exc)

    try:
        for row in rows:
            if row["tile_type"] == "device" and row["ref_id"] not in device_map:
                orphan_tile_ids.append(str(row["id"]))
                continue
            tile = {
                "id": row["id"],
                "tile_type": row["tile_type"],
                "label": row["label"],
                "ref_id": row["ref_id"],
                "payload": json.loads(row["payload_json"]),
                "data": {},
                "error": None,
            }
            if tile["tile_type"] in ("device", "group"):
                tile["automation_rules"] = _load_automation_rules_for_target("tile", tile["id"])
            tiles.append(tile)

            tile_type = row["tile_type"]
            if tile_type in ("weather", "spotify", "device", "group", "automation"):
                future = executor.submit(resolve_live, row)
                pending[future] = len(tiles) - 1

        unresolved = set(pending.keys())
        while unresolved:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            done, unresolved = wait(unresolved, timeout=min(_DASHBOARD_TASK_TIMEOUT_SECONDS, remaining), return_when=FIRST_COMPLETED)
            for fut in done:
                idx = pending.get(fut)
                if idx is None:
                    continue
                try:
                    data, err = fut.result(timeout=0)
                    tiles[idx]["data"] = data
                    tiles[idx]["error"] = err
                except Exception as exc:  # best-effort dashboard render
                    tiles[idx]["error"] = str(exc)

        for fut in unresolved:
            idx = pending.get(fut)
            if idx is None:
                continue
            tile = tiles[idx]
            if tile["tile_type"] == "device" and tile["ref_id"] in device_map:
                dev = device_map[tile["ref_id"]]
                try:
                    stale = _dashboard_cached_device_status(dev, quick=True)
                    stale["device_type"] = dev.get("type")
                    stale["stale"] = True
                    tile["data"] = stale
                    tile["error"] = None
                    continue
                except Exception:
                    pass
            if tile["tile_type"] == "group":
                try:
                    payload = tile.get("payload", {})
                    if not isinstance(payload, dict):
                        payload = {}
                    tile["data"] = _resolve_group_tile_data(payload, device_map)
                    tile["data"]["stale"] = True
                    tile["error"] = None
                    continue
                except Exception:
                    pass
            if tile["tile_type"] == "automation":
                try:
                    payload = tile.get("payload", {})
                    if not isinstance(payload, dict):
                        payload = {}
                    tile["data"] = _resolve_automation_tile_data(payload, device_map)
                    tile["data"]["stale"] = True
                    tile["error"] = None
                    continue
                except Exception:
                    pass
            tile["error"] = "Timed out fetching live status"
    finally:
        executor.shutdown(wait=False, cancel_futures=True)
    if orphan_tile_ids:
        cleanup = get_connection()
        cleanup.executemany("DELETE FROM main_tiles WHERE id=?", [(tile_id,) for tile_id in orphan_tile_ids])
        cleanup.commit()
        cleanup.close()
        append_event("main_orphan_tiles_removed", {"tile_ids": orphan_tile_ids, "count": len(orphan_tile_ids)})
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


@app.post("/api/main/tiles/{tile_id}/group-action", dependencies=[Depends(require_auth_if_configured)])
def post_group_tile_action(tile_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="payload must be an object")
    requested_state = str(payload.get("state", "")).strip().lower()
    if requested_state not in {"on", "off", "toggle"}:
        raise HTTPException(status_code=400, detail="state must be one of: on, off, toggle")

    conn = get_connection()
    tile = conn.execute("SELECT * FROM main_tiles WHERE id=?", (tile_id,)).fetchone()
    if not tile:
        conn.close()
        raise HTTPException(status_code=404, detail="Tile not found")
    if str(tile["tile_type"] or "") != "group":
        conn.close()
        raise HTTPException(status_code=400, detail="Tile is not a group")
    try:
        tile_payload = json.loads(tile["payload_json"] or "{}")
    except Exception:
        tile_payload = {}
    if not isinstance(tile_payload, dict):
        tile_payload = {}
    group_kind, group_name, members = _group_members_from_source(tile_payload)
    if not members:
        conn.close()
        raise HTTPException(status_code=400, detail="Group has no members")

    device_ids = [str(item.get("device_id", "")).strip() for item in members if str(item.get("device_id", "")).strip()]
    placeholders = ",".join("?" for _ in device_ids) or "''"
    device_rows = {
        str(row["id"]): row
        for row in conn.execute(f"SELECT * FROM devices WHERE id IN ({placeholders})", tuple(device_ids)).fetchall()
    }
    conn.close()

    results, ok_count, error_count = _execute_group_members_action(
        requested_state=requested_state,
        members=members,
        device_rows=device_rows,
    )

    append_event(
        "group_tile_action",
        {
            "tile_id": tile_id,
            "label": str(tile["label"] or ""),
            "group_name": group_name or str(tile["label"] or ""),
            "group_kind": group_kind,
            "state": requested_state,
            "member_count": len(members),
            "ok_count": ok_count,
            "error_count": error_count,
        },
    )
    return {
        "ok": error_count == 0,
        "tile_id": tile_id,
        "state": requested_state,
        "member_count": len(members),
        "ok_count": ok_count,
        "error_count": error_count,
        "results": results,
    }


@app.post("/api/main/tiles/{tile_id}/run", dependencies=[Depends(require_auth_if_configured)])
def post_run_tile(tile_id: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    if payload is not None and not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="payload must be an object")

    conn = get_connection()
    tile = conn.execute("SELECT * FROM main_tiles WHERE id=?", (tile_id,)).fetchone()
    if not tile:
        conn.close()
        raise HTTPException(status_code=404, detail="Tile not found")
    try:
        tile_payload = json.loads(tile["payload_json"] or "{}")
    except Exception:
        tile_payload = {}
    if not isinstance(tile_payload, dict):
        tile_payload = {}

    tile_type = str(tile["tile_type"] or "").strip().lower()
    if tile_type == "group":
        conn.close()
        return post_group_tile_action(tile_id, payload or {"state": "toggle"})
    if tile_type != "automation":
        conn.close()
        raise HTTPException(status_code=400, detail="Tile is not runnable")

    action = str(tile_payload.get("action", "group")).strip().lower() or "group"
    if action != "group":
        conn.close()
        raise HTTPException(status_code=400, detail="Unsupported automation action")

    requested_state = str((payload or {}).get("state", tile_payload.get("state", "toggle"))).strip().lower() or "toggle"
    if requested_state not in {"on", "off", "toggle"}:
        conn.close()
        raise HTTPException(status_code=400, detail="state must be one of: on, off, toggle")

    group_kind, group_name, members = _group_members_from_source(tile_payload)
    if not members:
        conn.close()
        raise HTTPException(status_code=400, detail="Automation target group has no members")

    device_ids = [str(item.get("device_id", "")).strip() for item in members if str(item.get("device_id", "")).strip()]
    placeholders = ",".join("?" for _ in device_ids) or "''"
    device_rows = {
        str(row["id"]): row
        for row in conn.execute(f"SELECT * FROM devices WHERE id IN ({placeholders})", tuple(device_ids)).fetchall()
    }
    conn.close()

    results, ok_count, error_count = _execute_group_members_action(
        requested_state=requested_state,
        members=members,
        device_rows=device_rows,
    )
    append_event(
        "automation_tile_run",
        {
            "tile_id": tile_id,
            "label": str(tile["label"] or ""),
            "group_name": group_name or str(tile["label"] or ""),
            "group_kind": group_kind,
            "state": requested_state,
            "member_count": len(members),
            "ok_count": ok_count,
            "error_count": error_count,
        },
    )
    return {
        "ok": error_count == 0,
        "tile_id": tile_id,
        "tile_type": tile_type,
        "action": action,
        "state": requested_state,
        "group_name": group_name,
        "group_kind": group_kind,
        "member_count": len(members),
        "ok_count": ok_count,
        "error_count": error_count,
        "results": results,
    }


@app.get("/api/main/tiles/{tile_id}/automation")
def get_tile_automation(tile_id: str) -> dict[str, Any]:
    conn = get_connection()
    tile = conn.execute("SELECT * FROM main_tiles WHERE id=?", (tile_id,)).fetchone()
    conn.close()
    if not tile:
        raise HTTPException(status_code=404, detail="Tile not found")
    rules = _load_automation_rules_for_target("tile", tile_id)
    return {
        "tile_id": tile_id,
        "tile_type": tile["tile_type"],
        "ref_id": tile["ref_id"],
        "rules": rules,
    }


@app.put("/api/main/tiles/{tile_id}/automation", dependencies=[Depends(require_auth_if_configured)])
def put_tile_automation(tile_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    conn = get_connection()
    tile = conn.execute("SELECT * FROM main_tiles WHERE id=?", (tile_id,)).fetchone()
    conn.close()
    if not tile:
        raise HTTPException(status_code=404, detail="Tile not found")
    rules_raw = payload.get("rules", []) if isinstance(payload, dict) else []
    if not isinstance(rules_raw, list):
        raise HTTPException(status_code=400, detail="rules must be a list")
    saved = _save_automation_rules_for_target(
        target_type="tile",
        target_id=tile_id,
        rules=[item for item in rules_raw if isinstance(item, dict)],
        default_device_id=str(tile["ref_id"] or "").strip(),
        default_channel_key=str((payload.get("default_channel_key", "") if isinstance(payload, dict) else "")).strip(),
    )
    append_event("tile_automation_updated", {"tile_id": tile_id, "rule_count": len(saved)})
    return {"saved": True, "tile_id": tile_id, "rules": saved}


@app.patch("/api/main/tiles/{tile_id}", dependencies=[Depends(require_auth_if_configured)])
def patch_tile(tile_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="payload must be an object")

    updates: list[str] = []
    values: list[Any] = []

    if "label" in payload:
        updates.append("label=?")
        values.append(str(payload.get("label", "")).strip())

    if "payload" in payload:
        raw_payload = payload.get("payload", {})
        if not isinstance(raw_payload, dict):
            raise HTTPException(status_code=400, detail="payload.payload must be an object")
        updates.append("payload_json=?")
        values.append(json.dumps(raw_payload))

    if not updates:
        raise HTTPException(status_code=400, detail="No supported fields to update")

    now = utc_now()
    updates.append("updated_at=?")
    values.append(now)
    values.append(tile_id)

    conn = get_connection()
    count = conn.execute(
        f"UPDATE main_tiles SET {', '.join(updates)} WHERE id=?",
        tuple(values),
    ).rowcount
    conn.commit()
    conn.close()

    if count == 0:
        raise HTTPException(status_code=404, detail="Tile not found")

    append_event("tile_updated", {"id": tile_id, "fields": [k for k in payload.keys() if k in ("label", "payload")]})
    return {"updated": True}


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
    automation_only = True
    if isinstance(payload, dict) and "automation_only" in payload:
        automation_only = bool(payload.get("automation_only"))
    results = scan_network(subnet, automation_only=automation_only)

    by_ip: dict[str, dict[str, Any]] = {}
    for row in results:
        ip = str(row.get("ip", "")).strip()
        if ip:
            by_ip[ip] = row

    def merge_candidate(
        *,
        ip: str,
        provider_hint: str,
        device_hint: str,
        score: int,
        source: str,
        name: str = "",
        hostname: str = "",
        mac: str = "",
        extra: dict[str, Any] | None = None,
    ) -> None:
        ip = str(ip or "").strip()
        if not ip:
            return
        row = by_ip.get(ip)
        if row is None:
            row = {
                "ip": ip,
                "mac": str(mac or "").strip(),
                "hostname": str(hostname or "").strip(),
                "name": str(name or "").strip(),
                "source": source,
                "device_hint": device_hint,
                "provider_hint": provider_hint,
                "score": int(score),
                "automation_candidate": True,
            }
            results.append(row)
            by_ip[ip] = row
        else:
            if int(row.get("score", 0)) < int(score):
                row["score"] = int(score)
            if str(row.get("provider_hint", "")).strip().lower() in ("", "unknown", "marker_match"):
                row["provider_hint"] = provider_hint
            if str(row.get("device_hint", "")).strip().lower() in ("", "unknown", "marker_match"):
                row["device_hint"] = device_hint
            if not str(row.get("name", "")).strip() and str(name).strip():
                row["name"] = str(name).strip()
            if not str(row.get("hostname", "")).strip() and str(hostname).strip():
                row["hostname"] = str(hostname).strip()
            if not str(row.get("mac", "")).strip() and str(mac).strip():
                row["mac"] = str(mac).strip()
            row["automation_candidate"] = True
        if extra:
            for key, value in extra.items():
                if value is None:
                    continue
                if isinstance(value, str):
                    if not value.strip():
                        continue
                    row[key] = value.strip()
                else:
                    row[key] = value

    tuya_count = 0
    moes_hub_count = 0
    subnet_hint = str(subnet or "").strip()
    single_ip_hint = _is_single_ipv4_host_hint(subnet_hint)
    tuya_local: dict[str, Any] = {"devices": [], "enabled": True}
    try:
        if not single_ip_hint:
            tuya_local = tuya_local_scan(subnet_hint=subnet_hint)
        for item in tuya_local.get("devices", []):
            if not isinstance(item, dict):
                continue
            merge_candidate(
                ip=str(item.get("ip", "")),
                provider_hint="tuya_local",
                device_hint="tuya_local",
                score=10,
                source="tuya_local_scan",
                name=str(item.get("name", "")),
                mac=str(item.get("mac", "")),
                extra={
                    "tuya_device_id": str(item.get("id", "")),
                    "tuya_version": str(item.get("version", "")),
                    "tuya_product_key": str(item.get("product_key", "")),
                },
            )
            tuya_count += 1
    except Exception:
        pass

    try:
        moes_local = discover_bhubw_local(subnet_hint=subnet_hint, tuya_local_override=tuya_local)
        for hub in moes_local.get("hubs", []):
            if not isinstance(hub, dict):
                continue
            hub_score = int(hub.get("score", 0))
            merge_candidate(
                ip=str(hub.get("ip", "")),
                provider_hint="moes_bhubw",
                device_hint="moes_hub",
                score=max(9, hub_score + 4),
                source="moes_discovery",
                name=str(hub.get("name", "")),
                hostname=str(hub.get("hostname", "")),
                mac=str(hub.get("mac", "")),
                extra={
                    "moes_hub_id": str(hub.get("id", "")),
                    "moes_hub_version": str(hub.get("version", "")),
                },
            )
            moes_hub_count += 1
    except Exception:
        pass

    if automation_only:
        results = [row for row in results if bool(row.get("automation_candidate"))]

    results.sort(key=lambda item: (-int(item.get("score", 0)), str(item.get("ip", ""))))
    append_event(
        "network_scan",
        {
            "count": len(results),
            "subnet_hint": subnet or "",
            "automation_only": automation_only,
            "tuya_local_merged": tuya_count,
            "moes_hubs_merged": moes_hub_count,
        },
    )
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
    base = _resolve_download_base_url(request)
    firmware_url = f"{base}/downloads/profiles/{profile_folder}/{firmware_name}"
    manifest_url = f"{base}/downloads/profiles/{profile_folder}/{manifest_name}"

    precheck = _run_ota_precheck(host, passcode)
    if not precheck.get("ok"):
        raise HTTPException(
            status_code=400,
            detail={
                "message": "OTA pre-check failed. Device is not ready for OTA push.",
                "precheck": precheck,
                "hint": "Confirm host/passcode and that /api/status and /api/pair are reachable.",
            },
        )

    return _start_profile_push_job(
        profile_id=profile_id,
        profile_name=str(profile.get("profile_name", profile_id)),
        device_id=device_id,
        host=host,
        firmware_url=firmware_url,
        manifest_url=manifest_url,
        passcode=passcode,
        mode="registered_device",
        precheck=precheck,
    )


@app.post("/api/firmware/profiles/{profile_id}/push-direct", dependencies=[Depends(require_auth_if_configured)])
def push_profile_to_host(profile_id: str, payload: dict[str, Any], request: Request) -> dict[str, Any]:
    profile = get_firmware_profile(profile_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Profile not found")

    host = str(payload.get("host", "")).strip() if isinstance(payload, dict) else ""
    passcode = str(payload.get("passcode", "")).strip() if isinstance(payload, dict) else ""
    if not host:
        raise HTTPException(status_code=400, detail="host is required")
    if not passcode:
        raise HTTPException(status_code=400, detail="passcode is required")

    try:
        firmware_path, manifest_path = get_profile_file_paths(profile)
    except (FileNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    profile_folder = profile.get("profile_folder", "")
    firmware_name = firmware_path.name
    manifest_name = manifest_path.name
    base = _resolve_download_base_url(request)
    firmware_url = f"{base}/downloads/profiles/{profile_folder}/{firmware_name}"
    manifest_url = f"{base}/downloads/profiles/{profile_folder}/{manifest_name}"

    precheck = _run_ota_precheck(host, passcode)
    if not precheck.get("ok"):
        raise HTTPException(
            status_code=400,
            detail={
                "message": "OTA pre-check failed. Device is not ready for OTA push.",
                "precheck": precheck,
                "hint": "Confirm host/passcode and that /api/status and /api/pair are reachable.",
            },
        )

    return _start_profile_push_job(
        profile_id=profile_id,
        profile_name=str(profile.get("profile_name", profile_id)),
        device_id="",
        host=host,
        firmware_url=firmware_url,
        manifest_url=manifest_url,
        passcode=passcode,
        mode="direct_host",
        precheck=precheck,
    )


@app.get("/api/firmware/profiles/push-jobs/{job_id}", dependencies=[Depends(require_auth_if_configured)])
def get_profile_push_job(job_id: str) -> dict[str, Any]:
    job = _profile_push_job_read(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


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
        raise HTTPException(
            status_code=400,
            detail={
                "message": str(exc),
                "build_id": exc.build_id,
                "log_file": str(exc.log_file),
                "hint": "Open the build log file for full stdout/stderr details.",
            },
        ) from exc
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
