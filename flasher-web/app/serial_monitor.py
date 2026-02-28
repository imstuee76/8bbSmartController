from __future__ import annotations

import threading
import uuid
from dataclasses import dataclass, field
from typing import Any

import serial

from .storage import append_event, utc_now

MAX_MONITOR_OUTPUT = 250_000


@dataclass
class MonitorSession:
    session_id: str
    port: str
    baud: int
    started_at: str
    status: str = "running"
    output: str = ""
    error: str = ""
    stopped_at: str = ""
    lock: threading.Lock = field(default_factory=threading.Lock)
    stop_event: threading.Event = field(default_factory=threading.Event)
    thread: threading.Thread | None = None


_sessions: dict[str, MonitorSession] = {}
_sessions_lock = threading.Lock()


def _port_key(port: str) -> str:
    return (port or "").strip().lower()


def _trim(text: str) -> str:
    if len(text) <= MAX_MONITOR_OUTPUT:
        return text
    return text[-MAX_MONITOR_OUTPUT:]


def _append_line(session: MonitorSession, line: str) -> None:
    with session.lock:
        merged = (session.output + ("\n" if session.output else "") + line).strip("\n")
        session.output = _trim(merged)


def _run_monitor(session: MonitorSession) -> None:
    try:
        with serial.Serial(session.port, session.baud, timeout=0.2) as ser:
            _append_line(session, f"[monitor] connected: {session.port} @ {session.baud}")
            while not session.stop_event.is_set():
                data = ser.readline()
                if not data:
                    continue
                text = data.decode("utf-8", errors="replace").rstrip("\r\n")
                if text:
                    _append_line(session, text)
    except Exception as exc:
        with session.lock:
            session.status = "error"
            session.error = str(exc)
        _append_line(session, f"[monitor] error: {exc}")
    finally:
        with session.lock:
            if session.status == "running":
                session.status = "stopped"
            session.stopped_at = utc_now()
        append_event(
            "serial_monitor_finished",
            {
                "session_id": session.session_id,
                "port": session.port,
                "baud": session.baud,
                "status": session.status,
                "error": session.error,
            },
        )


def start_serial_monitor(port: str, baud: int) -> dict[str, Any]:
    device = (port or "").strip()
    if not device:
        raise ValueError("port is required")
    if baud < 1200 or baud > 4_000_000:
        raise ValueError("invalid baud")

    session_id = str(uuid.uuid4())
    session = MonitorSession(
        session_id=session_id,
        port=device,
        baud=baud,
        started_at=utc_now(),
    )
    thread = threading.Thread(target=_run_monitor, args=(session,), daemon=True)
    session.thread = thread

    with _sessions_lock:
        _sessions[session_id] = session

    thread.start()
    append_event("serial_monitor_started", {"session_id": session_id, "port": device, "baud": baud})
    return get_serial_monitor(session_id)


def get_serial_monitor(session_id: str) -> dict[str, Any]:
    with _sessions_lock:
        session = _sessions.get(session_id)
    if not session:
        raise KeyError("Serial monitor session not found")
    with session.lock:
        return {
            "session_id": session.session_id,
            "port": session.port,
            "baud": session.baud,
            "status": session.status,
            "error": session.error,
            "started_at": session.started_at,
            "stopped_at": session.stopped_at,
            "output": session.output,
        }


def stop_serial_monitor(session_id: str) -> dict[str, Any]:
    with _sessions_lock:
        session = _sessions.get(session_id)
    if not session:
        raise KeyError("Serial monitor session not found")

    with session.lock:
        if session.status == "running":
            session.status = "stopping"
    session.stop_event.set()
    if session.thread and session.thread.is_alive():
        session.thread.join(timeout=1.5)
    return get_serial_monitor(session_id)


def has_active_monitor_on_port(port: str) -> bool:
    key = _port_key(port)
    if not key:
        return False
    with _sessions_lock:
        for session in _sessions.values():
            if _port_key(session.port) != key:
                continue
            if session.status in ("running", "stopping"):
                return True
    return False


def stop_serial_monitors_for_port(port: str) -> list[str]:
    key = _port_key(port)
    if not key:
        return []
    with _sessions_lock:
        ids = [
            session_id
            for session_id, session in _sessions.items()
            if _port_key(session.port) == key and session.status in ("running", "stopping")
        ]
    stopped: list[str] = []
    for session_id in ids:
        try:
            stop_serial_monitor(session_id)
            stopped.append(session_id)
        except KeyError:
            continue
    return stopped


def stop_all_serial_monitors() -> list[str]:
    with _sessions_lock:
        ids = [
            session_id
            for session_id, session in _sessions.items()
            if session.status in ("running", "stopping")
        ]
    stopped: list[str] = []
    for session_id in ids:
        try:
            stop_serial_monitor(session_id)
            stopped.append(session_id)
        except KeyError:
            continue
    return stopped
