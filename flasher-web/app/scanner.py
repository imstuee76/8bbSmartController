from __future__ import annotations

import re
import subprocess
from typing import Any

import httpx

ARP_RE = re.compile(r"(?:\(|\s)(\d+\.\d+\.\d+\.\d+)(?:\)|\s).{0,40}(([0-9a-f]{2}[:-]){5}[0-9a-f]{2})", re.IGNORECASE)
AUTOMATION_MARKERS = (
    "esp",
    "espressif",
    "relay",
    "switch",
    "light",
    "lamp",
    "rgb",
    "fan",
    "tuya",
    "moes",
    "bhub",
    "smartlife",
    "tasmota",
    "8bb",
)


def _marker_score(text: str) -> int:
    blob = (text or "").lower()
    return sum(1 for marker in AUTOMATION_MARKERS if marker in blob)


def _quick_http_probe(ip: str) -> tuple[str, int]:
    # Keep probing short to preserve snappy scan UX.
    try:
        with httpx.Client(timeout=0.35) as client:
            status_res = client.get(f"http://{ip}/api/status")
        if status_res.status_code < 400:
            try:
                body = status_res.json()
                device_type = str(body.get("device_type", "") or body.get("type", "")).strip().lower()
                hint = device_type if device_type else "esp_firmware"
                return hint, 8
            except Exception:
                return "esp_firmware", 6
    except Exception:
        pass

    try:
        with httpx.Client(timeout=0.3) as client:
            root_res = client.get(f"http://{ip}/")
        if root_res.status_code < 400:
            body = root_res.text.lower()
            if any(marker in body for marker in ("tuya", "smartlife", "moes", "gateway", "bhub")):
                return "tuya_or_moes", 4
    except Exception:
        pass

    return "unknown", 0


def scan_network(
    subnet_hint: str | None = None,
    resolve_hostnames: bool = False,
    automation_only: bool = False,
) -> list[dict[str, Any]]:
    _ = subnet_hint
    results: list[dict[str, Any]] = []

    try:
        output = subprocess.check_output(["arp", "-a"], text=True, stderr=subprocess.STDOUT)
        for line in output.splitlines():
            match = ARP_RE.search(line)
            if not match:
                continue
            ip = match.group(1)
            mac = match.group(2).replace("-", ":").lower()
            hostname = ""
            if resolve_hostnames:
                import socket

                try:
                    hostname = socket.gethostbyaddr(ip)[0]
                except OSError:
                    hostname = ""
            results.append(
                {
                    "ip": ip,
                    "mac": mac,
                    "hostname": hostname,
                    "source": "arp",
                    "device_hint": "unknown",
                }
            )
    except Exception:
        pass

    # Dedupe by IP before enrichment/filter.
    deduped: list[dict[str, Any]] = []
    seen_ips: set[str] = set()
    for row in results:
        ip = str(row.get("ip", "")).strip()
        if not ip or ip in seen_ips:
            continue
        seen_ips.add(ip)
        deduped.append(row)
    results = deduped

    if results:
        probe_budget = 20
        filtered: list[dict[str, Any]] = []
        for item in results:
            ip = str(item.get("ip", "")).strip()
            host = str(item.get("hostname", "")).strip()
            mac = str(item.get("mac", "")).strip()
            score = _marker_score(f"{host} {mac}")
            provider_hint = "unknown"
            if score > 0:
                provider_hint = "marker_match"

            if ip and probe_budget > 0:
                hint, boost = _quick_http_probe(ip)
                probe_budget -= 1
                if boost > 0:
                    provider_hint = hint
                    score += boost
                    if hint not in ("unknown", "marker_match") and item.get("device_hint", "unknown") == "unknown":
                        item["device_hint"] = hint

            candidate = score >= 2
            item["automation_candidate"] = candidate
            item["provider_hint"] = provider_hint
            item["score"] = score
            if not automation_only or candidate:
                filtered.append(item)
        results = filtered

    if not results:
        results.append(
            {
                "ip": "192.168.1.200",
                "mac": "00:00:00:00:00:00",
                "hostname": "sample-esp32",
                "source": "sample",
                "device_hint": "relay_switch",
            }
        )

    return results
