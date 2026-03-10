from __future__ import annotations

import json
import re
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from .storage import LOG_DIR, ensure_data_layout

SESSION_COOKIE_NAME = "8bb_client_session_id"
_SAFE_SEGMENT_RE = re.compile(r"[^a-zA-Z0-9._-]+")


def local_now_iso() -> str:
    return datetime.now().astimezone().isoformat()


def local_day_compact() -> str:
    return datetime.now().astimezone().strftime("%Y%m%d")


def _safe_segment(value: str, fallback: str) -> str:
    raw = (value or "").strip()
    cleaned = _SAFE_SEGMENT_RE.sub("-", raw).strip(".-")
    if not cleaned:
        cleaned = fallback
    return cleaned[:80]


def get_or_create_client_session_id(current: str | None) -> tuple[str, bool]:
    if current:
        return _safe_segment(current, f"client-{uuid.uuid4().hex[:12]}"), False
    stamp = datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")
    return f"client-{stamp}-{uuid.uuid4().hex[:8]}", True


def append_activity(session_id: str, payload: dict[str, Any]) -> str:
    day = local_day_compact()
    ensure_data_layout()
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"backend-activity-{day}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {"time": local_now_iso(), "session_id": _safe_segment(session_id, "session"), **payload}
    with path.open("a", encoding="utf-8") as fp:
        fp.write(json.dumps(record, ensure_ascii=True) + "\n")
    return str(path)


def append_error(session_id: str, payload: dict[str, Any]) -> str:
    day = local_day_compact()
    ensure_data_layout()
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"backend-errors-{day}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {"time": local_now_iso(), "session_id": _safe_segment(session_id, "session"), **payload}
    with path.open("a", encoding="utf-8") as fp:
        fp.write(json.dumps(record, ensure_ascii=True) + "\n")
    return str(path)
