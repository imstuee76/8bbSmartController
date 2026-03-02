from __future__ import annotations

import ipaddress
import platform
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import httpx

ARP_RE = re.compile(r"(?:\(|\s)(\d+\.\d+\.\d+\.\d+)(?:\)|\s).{0,40}(([0-9a-f]{2}[:-]){5}[0-9a-f]{2})", re.IGNORECASE)
IP_NEIGH_RE = re.compile(
    r"^\s*(\d+\.\d+\.\d+\.\d+)\s+dev\s+\S+(?:\s+lladdr\s+(([0-9a-f]{2}:){5}[0-9a-f]{2}))?.*$",
    re.IGNORECASE,
)
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


def _sanitize_name(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    # Avoid noisy placeholders.
    if text.lower() in ("unknown", "none", "null", "n/a"):
        return ""
    return text[:96]


def _quick_http_probe(ip: str) -> tuple[str, int, str]:
    # Keep probing short, but long enough for slower ESP web handlers.
    try:
        with httpx.Client(timeout=1.2) as client:
            status_res = client.get(f"http://{ip}/api/status")
        if status_res.status_code < 400:
            try:
                body = status_res.json()
                device_type = str(body.get("device_type", "") or body.get("type", "")).strip().lower()
                hint = device_type if device_type else "esp_firmware"
                name = ""
                if isinstance(body, dict):
                    name = (
                        _sanitize_name(body.get("name"))
                        or _sanitize_name(body.get("device_name"))
                        or _sanitize_name(body.get("hostname"))
                        or _sanitize_name(body.get("title"))
                    )
                return hint, 8, name
            except Exception:
                return "esp_firmware", 6, ""
    except Exception:
        pass

    try:
        with httpx.Client(timeout=1.0) as client:
            status_res = client.get(f"http://{ip}/status")
        if status_res.status_code < 400:
            text = status_res.text.lower()
            if "relay" in text or "esp" in text or "switch" in text or "light" in text:
                return "esp_firmware", 5, ""
    except Exception:
        pass

    try:
        with httpx.Client(timeout=0.8) as client:
            root_res = client.get(f"http://{ip}/")
        if root_res.status_code < 400:
            body = root_res.text.lower()
            if any(marker in body for marker in ("tuya", "smartlife", "moes", "gateway", "bhub")):
                return "tuya_or_moes", 4, ""
    except Exception:
        pass

    return "unknown", 0, ""


def _network_from_hint(subnet_hint: str | None) -> ipaddress.IPv4Network | None:
    raw = str(subnet_hint or "").strip()
    if not raw:
        return None

    # "192.168.50" -> /24
    m_3 = re.fullmatch(r"(\d{1,3})\.(\d{1,3})\.(\d{1,3})", raw)
    if m_3:
        octets = [int(m_3.group(i)) for i in (1, 2, 3)]
        if all(0 <= o <= 255 for o in octets):
            return ipaddress.ip_network(f"{octets[0]}.{octets[1]}.{octets[2]}.0/24", strict=False)
        return None

    # "192.168.50.88" -> probe this host directly
    m_4 = re.fullmatch(r"(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})", raw)
    if m_4:
        octets = [int(m_4.group(i)) for i in (1, 2, 3, 4)]
        if all(0 <= o <= 255 for o in octets):
            return ipaddress.ip_network(f"{octets[0]}.{octets[1]}.{octets[2]}.{octets[3]}/32", strict=False)
        return None

    # CIDR input
    if "/" in raw:
        try:
            net = ipaddress.ip_network(raw, strict=False)
        except ValueError:
            return None
        return net if isinstance(net, ipaddress.IPv4Network) else None

    return None


def _ping_once(ip: str, timeout_ms: int = 240) -> None:
    os_name = platform.system().lower()
    if "windows" in os_name:
        cmd = ["ping", "-n", "1", "-w", str(timeout_ms), ip]
    else:
        cmd = ["ping", "-c", "1", "-W", "1", ip]
    try:
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception:
        pass


def _probe_ip_candidate(ip: str) -> dict[str, Any] | None:
    hint, boost, name = _quick_http_probe(ip)
    if boost <= 0:
        return None
    return {
        "ip": ip,
        "mac": "",
        "hostname": "",
        "name": name,
        "source": "http_probe",
        "device_hint": hint if hint not in ("unknown", "marker_match") else "unknown",
        "provider_hint": hint,
        "score": boost,
        "automation_candidate": True,
    }


def _active_http_probe(network: ipaddress.IPv4Network, max_hosts: int = 256) -> list[dict[str, Any]]:
    hosts = [str(ip) for ip in network.hosts()]
    if len(hosts) > max_hosts:
        hosts = hosts[:max_hosts]
    if not hosts:
        return []
    out: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=64) as pool:
        for item in pool.map(_probe_ip_candidate, hosts):
            if item:
                out.append(item)
    return out


def _collect_neighbors(resolve_hostnames: bool) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []

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
            rows.append(
                {
                    "ip": ip,
                    "mac": mac,
                    "hostname": hostname,
                    "name": hostname,
                    "source": "arp",
                    "device_hint": "unknown",
                }
            )
    except Exception:
        pass

    if rows:
        return rows

    # Linux fallback when `arp` isn't present.
    try:
        output = subprocess.check_output(["ip", "-4", "neigh"], text=True, stderr=subprocess.STDOUT)
        for line in output.splitlines():
            m = IP_NEIGH_RE.match(line)
            if not m:
                continue
            ip = m.group(1)
            mac = (m.group(2) or "").lower()
            if not mac or mac == "00:00:00:00:00:00":
                continue
            rows.append(
                {
                    "ip": ip,
                    "mac": mac,
                    "hostname": "",
                    "name": "",
                    "source": "ip_neigh",
                    "device_hint": "unknown",
                }
            )
    except Exception:
        pass

    return rows


def prime_neighbors(subnet_hint: str | None = None) -> int:
    network = _network_from_hint(subnet_hint)
    if network is None:
        return 0

    # Keep bounded and quick.
    hosts = [str(ip) for ip in network.hosts()]
    if len(hosts) > 256:
        hosts = hosts[:256]
    if not hosts:
        return 0

    with ThreadPoolExecutor(max_workers=64) as pool:
        list(pool.map(_ping_once, hosts))
    return len(hosts)


def scan_network(
    subnet_hint: str | None = None,
    resolve_hostnames: bool = False,
    automation_only: bool = False,
) -> list[dict[str, Any]]:
    network = _network_from_hint(subnet_hint)
    if network is not None:
        # Warm ARP table for the requested subnet before reading arp cache.
        prime_neighbors(str(network))

    results: list[dict[str, Any]] = _collect_neighbors(resolve_hostnames)

    # Dedupe by IP before enrichment/filter.
    deduped: list[dict[str, Any]] = []
    seen_ips: set[str] = set()
    for row in results:
        ip = str(row.get("ip", "")).strip()
        if network is not None:
            try:
                if ipaddress.ip_address(ip) not in network:
                    continue
            except ValueError:
                continue
        if not ip or ip in seen_ips:
            continue
        seen_ips.add(ip)
        deduped.append(row)
    results = deduped

    if results:
        # In automation-only mode we should probe all neighbor entries to avoid
        # missing valid ESP devices that appear late in ARP order.
        probe_budget = len(results) if automation_only else 20
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
                hint, boost, friendly_name = _quick_http_probe(ip)
                probe_budget -= 1
                if boost > 0:
                    provider_hint = hint
                    score += boost
                    if hint not in ("unknown", "marker_match") and item.get("device_hint", "unknown") == "unknown":
                        item["device_hint"] = hint
                    if friendly_name and not str(item.get("name", "")).strip():
                        item["name"] = friendly_name

            candidate = score >= 1
            item["automation_candidate"] = candidate
            item["provider_hint"] = provider_hint
            item["score"] = score
            if not automation_only or candidate:
                filtered.append(item)
        results = filtered

    # Active probe pass:
    # - Always in automation-only mode (more reliable on busy LANs).
    # - Also when neighbor table is sparse.
    should_active_probe = network is not None and (automation_only or len(results) < 2)
    if should_active_probe:
        active_hits = _active_http_probe(network)
        if active_hits:
            by_ip = {str(r.get("ip", "")).strip(): r for r in results}
            for hit in active_hits:
                ip = str(hit.get("ip", "")).strip()
                if not ip:
                    continue
                if ip in by_ip:
                    row = by_ip[ip]
                    row["score"] = max(int(row.get("score", 0)), int(hit.get("score", 0)))
                    if str(row.get("provider_hint", "unknown")) == "unknown":
                        row["provider_hint"] = hit.get("provider_hint", "unknown")
                    if str(row.get("device_hint", "unknown")) == "unknown":
                        row["device_hint"] = hit.get("device_hint", "unknown")
                    if not str(row.get("name", "")).strip():
                        row["name"] = str(hit.get("name", "")).strip()
                    row["automation_candidate"] = True
                else:
                    results.append(hit)

        if automation_only:
            results = [row for row in results if bool(row.get("automation_candidate"))]

    return results
