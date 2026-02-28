from __future__ import annotations

import platform
import re
import subprocess
from typing import Any
from urllib.parse import urlparse

import httpx

from .device_comm import fetch_device_status, normalize_device_host

IPV4_RE = re.compile(r"\b((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})\b")
HOST_RE = re.compile(r"\b([a-zA-Z0-9][a-zA-Z0-9-]{1,62}(?:\.local)?)\b")
NET_OK_RE = re.compile(
    r"NET_OK\s+name=(?P<name>\S+)\s+host=(?P<host>\S+)\s+ip=(?P<ip>[0-9.]+)\s+gw=(?P<gw>[0-9.]+)\s+mask=(?P<mask>[0-9.]+)",
    flags=re.IGNORECASE,
)
NET_AP_RE = re.compile(
    r"NET_AP\s+name=(?P<name>\S+)\s+ap_ssid=(?P<ssid>\S+)\s+ip=(?P<ip>[0-9.]+)\s+gw=(?P<gw>[0-9.]+)\s+mask=(?P<mask>[0-9.]+)",
    flags=re.IGNORECASE,
)
WIFI_REASON_RE = re.compile(r"reason\s*=\s*(\d+)")


def extract_ipv4_candidates(text: str) -> list[str]:
    found = IPV4_RE.findall(text or "")
    seen: set[str] = set()
    out: list[str] = []
    for ip in found:
        if ip in seen:
            continue
        seen.add(ip)
        out.append(ip)
    return out


def extract_host_candidates(text: str) -> list[str]:
    found = HOST_RE.findall(text or "")
    seen: set[str] = set()
    out: list[str] = []
    for host in found:
        h = host.strip().lower()
        if not h or h.count(".") > 3:
            continue
        if h.startswith("http") or h in {"connected", "disconnected", "monitor"}:
            continue
        if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", h):
            continue
        if h in seen:
            continue
        seen.add(h)
        out.append(h)
    return out


def _host_for_ping(host_or_url: str) -> str:
    raw = (host_or_url or "").strip()
    if not raw:
        raise ValueError("host is required")

    if raw.startswith("http://") or raw.startswith("https://"):
        parsed = urlparse(raw)
        host = parsed.hostname or ""
    else:
        host = raw.split("/")[0]
        if ":" in host and host.count(":") == 1:
            host = host.split(":", 1)[0]
    host = host.strip()
    if not host:
        raise ValueError("host is invalid")
    return host


def ping_host(host_or_url: str, timeout_ms: int = 1500) -> dict[str, Any]:
    target = _host_for_ping(host_or_url)
    os_name = platform.system().lower()
    if "windows" in os_name:
        cmd = ["ping", "-n", "1", "-w", str(timeout_ms), target]
    else:
        timeout_sec = max(1, int(round(timeout_ms / 1000)))
        cmd = ["ping", "-c", "1", "-W", str(timeout_sec), target]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    output = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
    latency_match = re.search(r"time[=<]\s*([0-9]+)\s*ms", output, flags=re.IGNORECASE)
    latency_ms = int(latency_match.group(1)) if latency_match else None
    return {
        "ok": proc.returncode == 0,
        "target": target,
        "return_code": proc.returncode,
        "latency_ms": latency_ms,
        "output_tail": output[-1800:],
    }


def test_device_status(host: str) -> dict[str, Any]:
    try:
        status = fetch_device_status(host)
        return {"ok": True, "host": host, "status": status}
    except Exception as exc:
        return {"ok": False, "host": host, "error": str(exc)}


def probe_status_quick(host: str, timeout: float = 1.2) -> dict[str, Any]:
    base = normalize_device_host(host)
    try:
        with httpx.Client(timeout=timeout) as client:
            res = client.get(f"{base}/api/status")
        if res.status_code >= 400:
            return {"ok": False, "host": host, "status_code": res.status_code}
        body = res.json()
        return {"ok": True, "host": host, "status": body}
    except Exception as exc:
        return {"ok": False, "host": host, "error": str(exc)}


def test_device_pair(host: str, passcode: str) -> dict[str, Any]:
    base = normalize_device_host(host)
    payload = {"passcode": passcode}
    try:
        with httpx.Client(timeout=8) as client:
            res = client.post(f"{base}/api/pair", json=payload)
        body_text = res.text.strip()
        body: Any
        try:
            body = res.json() if body_text else {}
        except Exception:
            body = body_text
        return {
            "ok": res.status_code < 400,
            "host": host,
            "status_code": res.status_code,
            "response": body,
        }
    except Exception as exc:
        return {"ok": False, "host": host, "error": str(exc)}


def parse_serial_network_summary(text: str) -> dict[str, Any]:
    summary: dict[str, Any] = {"mode": "unknown"}
    lines = (text or "").splitlines()
    for line in lines:
        m_ok = NET_OK_RE.search(line)
        if m_ok:
            summary.update(
                {
                    "mode": "sta",
                    "device_name": m_ok.group("name"),
                    "hostname": m_ok.group("host"),
                    "ip": m_ok.group("ip"),
                    "gateway": m_ok.group("gw"),
                    "subnet_mask": m_ok.group("mask"),
                    "status_line": line,
                }
            )
        m_ap = NET_AP_RE.search(line)
        if m_ap:
            summary.update(
                {
                    "mode": "ap",
                    "device_name": m_ap.group("name"),
                    "ap_ssid": m_ap.group("ssid"),
                    "ip": m_ap.group("ip"),
                    "gateway": m_ap.group("gw"),
                    "subnet_mask": m_ap.group("mask"),
                    "status_line": line,
                }
            )
        reason = WIFI_REASON_RE.search(line)
        if reason:
            summary["last_wifi_reason"] = int(reason.group(1))
            summary["last_wifi_reason_line"] = line
    return summary
