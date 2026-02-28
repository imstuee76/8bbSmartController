from __future__ import annotations

import platform
import re
import subprocess
from typing import Any

ARP_RE = re.compile(r"(?:\(|\s)(\d+\.\d+\.\d+\.\d+)(?:\)|\s).{0,40}(([0-9a-f]{2}[:-]){5}[0-9a-f]{2})", re.IGNORECASE)


def scan_network(subnet_hint: str | None = None, resolve_hostnames: bool = False) -> list[dict[str, Any]]:
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
