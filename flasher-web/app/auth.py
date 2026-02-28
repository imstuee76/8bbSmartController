from __future__ import annotations

import secrets
import time
from threading import Lock
from typing import Any

from fastapi import Header, HTTPException

from .security import hash_passcode, verify_passcode
from .storage import get_setting, set_setting

SESSION_TTL_SECONDS = 30 * 24 * 60 * 60
SESSIONS_SETTING_KEY = "auth_sessions"
_sessions: dict[str, dict[str, Any]] = {}
_sessions_lock = Lock()


def _normalize_sessions(raw: Any) -> dict[str, dict[str, Any]]:
    now = time.time()
    out: dict[str, dict[str, Any]] = {}
    if not isinstance(raw, dict):
        return out
    for token, item in raw.items():
        if not isinstance(token, str) or not isinstance(item, dict):
            continue
        username = str(item.get("username", "")).strip()
        try:
            expires_at = float(item.get("expires_at", 0))
        except Exception:
            expires_at = 0
        if not username or expires_at <= now:
            continue
        out[token] = {"username": username, "expires_at": expires_at}
    return out


def _load_sessions_from_storage() -> dict[str, dict[str, Any]]:
    stored = get_setting(SESSIONS_SETTING_KEY)
    normalized = _normalize_sessions(stored)
    # Rewrite normalized value so expired/bad records are cleaned up.
    if stored != normalized:
        set_setting(SESSIONS_SETTING_KEY, normalized)
    return normalized


def _save_sessions_to_storage(sessions: dict[str, dict[str, Any]]) -> None:
    set_setting(SESSIONS_SETTING_KEY, sessions)


def auth_status() -> dict[str, bool]:
    admin = get_setting("admin")
    return {"configured": bool(admin.get("username")) and bool(admin.get("password_hash"))}


def setup_admin(username: str, password: str) -> None:
    status = auth_status()
    if status["configured"]:
        raise ValueError("Admin is already configured")
    set_setting("admin", {"username": username, "password_hash": hash_passcode(password)})


def login_admin(username: str, password: str) -> str:
    admin = get_setting("admin")
    if not admin.get("username") or not admin.get("password_hash"):
        raise ValueError("Admin is not configured")

    if username != admin["username"] or not verify_passcode(password, admin.get("password_hash")):
        raise PermissionError("Invalid credentials")

    token = secrets.token_urlsafe(32)
    with _sessions_lock:
        live = _load_sessions_from_storage()
        # Keep recent sessions only.
        if len(live) > 64:
            ordered = sorted(live.items(), key=lambda kv: float(kv[1].get("expires_at", 0)), reverse=True)
            live = dict(ordered[:64])
        live[token] = {"username": username, "expires_at": time.time() + SESSION_TTL_SECONDS}
        _sessions.clear()
        _sessions.update(live)
        _save_sessions_to_storage(live)
    return token


def _validate_token(token: str) -> bool:
    with _sessions_lock:
        item = _sessions.get(token)
        now = time.time()
        if item and float(item.get("expires_at", 0)) >= now:
            return True

        live = _load_sessions_from_storage()
        _sessions.clear()
        _sessions.update(live)
        item = live.get(token)
        if not item:
            return False
        if float(item.get("expires_at", 0)) < now:
            live.pop(token, None)
            _sessions.pop(token, None)
            _save_sessions_to_storage(live)
            return False
        return True


def require_auth_if_configured(x_auth_token: str | None = Header(default=None)) -> None:
    if not auth_status()["configured"]:
        return
    if not x_auth_token or not _validate_token(x_auth_token):
        raise HTTPException(status_code=401, detail="Authentication required")
