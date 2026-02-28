from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[2]
DATA_DIR = ROOT_DIR / "data"
LOG_DIR = DATA_DIR / "logs"
DB_PATH = DATA_DIR / "flasher.db"
EVENT_LOG_PATH = LOG_DIR / "events.jsonl"

_db_lock = Lock()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_data_layout() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "firmware").mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "ota").mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "firmware_profiles").mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "backups").mkdir(parents=True, exist_ok=True)


def get_connection() -> sqlite3.Connection:
    ensure_data_layout()
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    ensure_data_layout()
    with _db_lock:
        conn = get_connection()
        cur = conn.cursor()
        cur.executescript(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                host TEXT,
                mac TEXT,
                passcode_hash TEXT,
                passcode_enc TEXT,
                ip_mode TEXT NOT NULL DEFAULT 'dhcp',
                static_ip TEXT,
                gateway TEXT,
                subnet_mask TEXT,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_seen_at TEXT
            );

            CREATE TABLE IF NOT EXISTS device_channels (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id TEXT NOT NULL,
                channel_key TEXT NOT NULL,
                channel_name TEXT NOT NULL,
                channel_kind TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                UNIQUE(device_id, channel_key),
                FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS main_tiles (
                id TEXT PRIMARY KEY,
                tile_type TEXT NOT NULL,
                ref_id TEXT,
                label TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS flash_jobs (
                id TEXT PRIMARY KEY,
                device_id TEXT,
                port TEXT NOT NULL,
                baud INTEGER NOT NULL,
                firmware_path TEXT NOT NULL,
                status TEXT NOT NULL,
                output TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                started_at TEXT,
                finished_at TEXT
            );
            """
        )
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(devices)").fetchall()}
        if "passcode_enc" not in columns:
            conn.execute("ALTER TABLE devices ADD COLUMN passcode_enc TEXT")
        conn.commit()
        conn.close()


DEFAULT_SETTINGS = {
    "display": {
        "resolution": "1920x1080",
        "orientation": "landscape",
        "scale": 1.0,
    },
    "spotify": {
        "client_id": "",
        "client_secret": "",
        "redirect_uri": "",
        "refresh_token": "",
        "device_id": "",
    },
    "weather": {
        "provider": "openweather",
        "api_key": "",
        "location": "",
        "units": "metric",
    },
    "tuya": {
        "cloud_region": "",
        "client_id": "",
        "client_secret": "",
        "local_scan_enabled": True,
    },
    "scan": {
        "subnet_hint": "",
        "mdns_enabled": True,
    },
    "moes": {
        "hub_ip": "",
        "hub_device_id": "",
        "hub_local_key": "",
        "hub_version": "3.4",
        "last_discovered_at": "",
        "last_light_scan_at": "",
    },
    "ota": {
        "shared_key": "8bb-change-this-ota-key",
    },
    "admin": {
        "username": "",
        "password_hash": "",
    },
}


def set_setting(key: str, value: dict[str, Any]) -> None:
    now = utc_now()
    with _db_lock:
        conn = get_connection()
        conn.execute(
            """
            INSERT INTO settings(key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
            """,
            (key, json.dumps(value), now),
        )
        conn.commit()
        conn.close()


def get_setting(key: str) -> dict[str, Any]:
    with _db_lock:
        conn = get_connection()
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        conn.close()

    if row:
        return json.loads(row["value"])
    default_value = DEFAULT_SETTINGS.get(key, {})
    set_setting(key, default_value)
    return default_value


def append_event(event_type: str, payload: dict[str, Any]) -> None:
    ensure_data_layout()
    record = {
        "time": utc_now(),
        "type": event_type,
        "payload": payload,
    }
    with EVENT_LOG_PATH.open("a", encoding="utf-8") as fp:
        fp.write(json.dumps(record) + "\n")
