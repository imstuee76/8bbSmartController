from __future__ import annotations

from typing import Any

import httpx

from .integrations import tuya_local_scan
from .security import decrypt_secret
from .scanner import scan_network
from .storage import append_event, get_setting, set_setting, utc_now


def _text_blob(obj: dict[str, Any]) -> str:
    parts = []
    for k in ("ip", "mac", "hostname", "name", "device_hint", "product_name", "category"):
        parts.append(str(obj.get(k, "")))
    return " ".join(parts).lower()


def _parse_version(value: Any, fallback: float = 3.4) -> float:
    try:
        return float(str(value).strip())
    except Exception:
        return fallback


def _extract_dps(status: Any) -> dict[str, Any]:
    if not isinstance(status, dict):
        return {}
    dps = status.get("dps")
    if isinstance(dps, dict):
        return dps
    data = status.get("data")
    if isinstance(data, dict):
        inner = data.get("dps")
        if isinstance(inner, dict):
            return inner
    return {}


def _collect_subdevices(node: Any, out: dict[str, dict[str, Any]]) -> None:
    if isinstance(node, dict):
        cid = str(node.get("cid") or node.get("node_id") or "").strip()
        if cid and cid not in out:
            out[cid] = {
                "cid": cid,
                "name": str(node.get("name", "")).strip(),
                "online": node.get("online", node.get("is_online", None)),
                "raw": node,
            }
        cids = node.get("cids")
        if isinstance(cids, list):
            for item in cids:
                if isinstance(item, str):
                    raw_cid = item.strip()
                    if raw_cid and raw_cid not in out:
                        out[raw_cid] = {
                            "cid": raw_cid,
                            "name": "",
                            "online": None,
                            "raw": {"cid": raw_cid},
                        }
                else:
                    _collect_subdevices(item, out)
        for value in node.values():
            _collect_subdevices(value, out)
        return
    if isinstance(node, list):
        for value in node:
            _collect_subdevices(value, out)


def _is_likely_light(name_blob: str, dps: dict[str, Any]) -> bool:
    light_markers = ("light", "lamp", "bulb", "led", "rgb", "strip", "colour", "color")
    if any(marker in name_blob for marker in light_markers):
        return True
    light_dps = {"20", "21", "22", "23", "24", "25", "26", "27", "101"}
    return any(k in dps for k in light_dps)


def _find_onoff_dp(dps: dict[str, Any]) -> str | int:
    for key in ("1", "20", "101"):
        if key in dps and isinstance(dps[key], bool):
            return int(key)
    for key, value in dps.items():
        if isinstance(value, bool):
            try:
                return int(key)
            except Exception:
                return key
    return 1


def _find_brightness_dp(dps: dict[str, Any]) -> str | int | None:
    for key in ("22", "3", "2", "101"):
        if key in dps and isinstance(dps[key], int):
            return int(key)
    for key, value in dps.items():
        if isinstance(value, int):
            try:
                return int(key)
            except Exception:
                return key
    return None


def _resolve_hub_inputs(
    hub_device_id: str = "",
    hub_ip: str = "",
    hub_mac: str = "",
    hub_local_key: str = "",
    hub_version: str = "",
    subnet_hint: str = "",
) -> tuple[str, str, str, float, str]:
    moes_cfg = get_setting("moes")
    selected_hub = (hub_device_id or moes_cfg.get("hub_device_id", "")).strip()
    selected_ip = (hub_ip or moes_cfg.get("hub_ip", "")).strip()
    selected_mac = (hub_mac or moes_cfg.get("hub_mac", "")).strip().lower()
    selected_version_raw = (hub_version or str(moes_cfg.get("hub_version", "3.4"))).strip()

    selected_key = (hub_local_key or "").strip()
    if not selected_key:
        selected_key = decrypt_secret(str(moes_cfg.get("hub_local_key", ""))).strip()

    if (not selected_ip or not selected_hub or not selected_version_raw) and selected_hub:
        try:
            local_scan = tuya_local_scan()
            for item in local_scan.get("devices", []):
                if str(item.get("id", "")).strip() == selected_hub:
                    if not selected_ip:
                        selected_ip = str(item.get("ip", "")).strip()
                    if not selected_mac:
                        selected_mac = str(item.get("mac", "")).strip().lower()
                    if not selected_version_raw:
                        selected_version_raw = str(item.get("version", "")).strip()
                    break
        except Exception:
            pass

    if not selected_hub:
        selected_hub = f"bhubw-{selected_ip}" if selected_ip else "bhubw-local"

    # UX fallback: if user clicks "Discover Lights" without manually selecting a hub,
    # auto-pick the highest scored discovered hub candidate.
    if not selected_ip:
        try:
            discovered = discover_bhubw_local(subnet_hint=subnet_hint)
            hubs = discovered.get("hubs", [])
            if isinstance(hubs, list) and hubs:
                best = hubs[0] if isinstance(hubs[0], dict) else {}
                if selected_mac:
                    for candidate in hubs:
                        if not isinstance(candidate, dict):
                            continue
                        candidate_mac = str(candidate.get("mac", "")).strip().lower()
                        if candidate_mac and candidate_mac == selected_mac:
                            best = candidate
                            break
                if isinstance(best, dict):
                    best_ip = str(best.get("ip", "")).strip()
                    best_mac = str(best.get("mac", "")).strip().lower()
                    best_id = str(best.get("id", "")).strip()
                    best_ver = str(best.get("version", "")).strip()
                    if best_ip:
                        selected_ip = best_ip
                    if best_mac and not selected_mac:
                        selected_mac = best_mac
                    if not selected_hub or selected_hub == "bhubw-local":
                        selected_hub = best_id or f"bhubw-{best_ip}"
                    if not selected_version_raw and best_ver:
                        selected_version_raw = best_ver
        except Exception:
            pass

    return selected_hub, selected_ip, selected_key, _parse_version(selected_version_raw), selected_mac


def _create_hub_device(hub_id: str, hub_ip: str, local_key: str, version: float) -> Any:
    try:
        import tinytuya  # type: ignore
    except Exception as exc:
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    if not hub_ip:
        raise ValueError("MOES hub IP is required for LAN mode")
    if not local_key:
        raise ValueError("MOES hub local key is required for LAN mode")

    dev = tinytuya.Device(  # type: ignore[attr-defined]
        dev_id=hub_id,
        address=hub_ip,
        local_key=local_key,
        version=version,
        persist=False,
    )
    dev.set_version(version)
    dev.set_socketPersistent(False)
    return dev


def _create_child_device(parent: Any, cid: str) -> Any:
    try:
        import tinytuya  # type: ignore
    except Exception as exc:
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    child = tinytuya.Device(  # type: ignore[attr-defined]
        dev_id=cid,
        cid=cid,
        parent=parent,
    )
    return child


def discover_bhubw_local(subnet_hint: str = "") -> dict[str, Any]:
    results = scan_network(subnet_hint or "")
    hubs: list[dict[str, Any]] = []
    probe_budget = 12

    for item in results:
        blob = _text_blob(item)
        reasons: list[str] = []
        score = 0

        if "moes" in blob:
            score += 4
            reasons.append("contains 'moes'")
        if "bhub" in blob:
            score += 6
            reasons.append("contains 'bhub'")
        if "hub" in blob:
            score += 2
            reasons.append("contains 'hub'")
        if "gateway" in blob:
            score += 2
            reasons.append("contains 'gateway'")
        if "tuya" in blob:
            score += 2
            reasons.append("contains 'tuya'")

        ip = str(item.get("ip", "")).strip()
        if ip and score > 0 and probe_budget > 0:
            probe_budget -= 1
            try:
                with httpx.Client(timeout=1.5) as client:
                    res = client.get(f"http://{ip}/")
                if res.status_code < 400:
                    body = res.text.lower()
                    if "tuya" in body or "smartlife" in body or "gateway" in body:
                        score += 2
                        reasons.append("web response has tuya/gateway markers")
            except Exception:
                pass

        if score > 0:
            hubs.append(
                {
                    "ip": item.get("ip", ""),
                    "mac": item.get("mac", ""),
                    "hostname": item.get("hostname", ""),
                    "name": item.get("name", ""),
                    "score": score,
                    "reasons": reasons,
                }
            )

    tuya_local = {"devices": [], "enabled": True}
    try:
        tuya_local = tuya_local_scan()
    except Exception as exc:
        tuya_local = {"devices": [], "enabled": False, "error": str(exc)}

    # Enrich LAN hub candidates with Tuya local scan IDs/versions where possible.
    seen = {(str(h.get("ip", "")).strip(), str(h.get("id", "")).strip()) for h in hubs}
    for entry in tuya_local.get("devices", []):
        if not isinstance(entry, dict):
            continue
        ip = str(entry.get("ip", "")).strip()
        mac = str(entry.get("mac", "")).strip().lower()
        dev_id = str(entry.get("id", "")).strip()
        version = str(entry.get("version", "")).strip()
        marker_blob = _text_blob(
            {
                "id": dev_id,
                "product_name": entry.get("product_name", ""),
                "category": entry.get("category", ""),
                "device_hint": entry.get("product_key", ""),
            }
        )
        score = 3
        if any(x in marker_blob for x in ("hub", "gateway", "bhub", "moes")):
            score = 7

        matched = False
        for candidate in hubs:
            if ip and str(candidate.get("ip", "")).strip() == ip:
                if dev_id and not candidate.get("id"):
                    candidate["id"] = dev_id
                if version and not candidate.get("version"):
                    candidate["version"] = version
                if mac and not str(candidate.get("mac", "")).strip():
                    candidate["mac"] = mac
                candidate["score"] = max(int(candidate.get("score", 0)), score)
                candidate.setdefault("reasons", []).append("matched tuya local scan")
                matched = True
                break
        if matched:
            continue

        key = (ip, dev_id)
        if key in seen:
            continue
        seen.add(key)
        hubs.append(
            {
                "id": dev_id,
                "ip": ip,
                "version": version,
                "mac": mac,
                "hostname": "",
                "name": "",
                "score": score,
                "reasons": ["from tuya local scan"],
            }
        )

    hubs.sort(key=lambda h: h.get("score", 0), reverse=True)

    moes_cfg = get_setting("moes")
    moes_cfg["last_discovered_at"] = utc_now()
    set_setting("moes", moes_cfg)
    append_event("moes_local_discovery", {"hub_count": len(hubs), "subnet_hint": subnet_hint or ""})
    return {
        "hubs": hubs,
        "subnet_hint": subnet_hint or "",
        "raw_scan_count": len(results),
        "tuya_local_devices": tuya_local.get("devices", []),
        "tuya_local_enabled": tuya_local.get("enabled", True),
        "tuya_local_error": tuya_local.get("error", ""),
    }


def discover_bhubw_lights(
    hub_device_id: str = "",
    hub_ip: str = "",
    hub_mac: str = "",
    hub_local_key: str = "",
    hub_version: str = "",
    subnet_hint: str = "",
) -> dict[str, Any]:
    selected_hub, selected_ip, selected_key, selected_version, selected_mac = _resolve_hub_inputs(
        hub_device_id=hub_device_id,
        hub_ip=hub_ip,
        hub_mac=hub_mac,
        hub_local_key=hub_local_key,
        hub_version=hub_version,
        subnet_hint=subnet_hint,
    )
    parent = _create_hub_device(
        hub_id=selected_hub,
        hub_ip=selected_ip,
        local_key=selected_key,
        version=selected_version,
    )

    subdev_raw = parent.subdev_query()
    cids: dict[str, dict[str, Any]] = {}
    _collect_subdevices(subdev_raw, cids)

    hubs = [
        {
            "id": selected_hub,
            "ip": selected_ip,
            "mac": selected_mac,
            "name": "MOES BHUB-W",
            "version": str(selected_version),
            "online": True,
        }
    ]
    lights: list[dict[str, Any]] = []
    subdevices: list[dict[str, Any]] = []
    for cid, entry in cids.items():
        child = _create_child_device(parent, cid)
        status: dict[str, Any] = {}
        dps: dict[str, Any] = {}
        online = entry.get("online", None)
        try:
            status = child.status()
            dps = _extract_dps(status)
            if isinstance(status, dict) and online is None and "online" in status:
                online = status.get("online")
        except Exception:
            status = {}
            dps = {}

        name_blob = _text_blob({"name": entry.get("name", ""), "device_hint": str(entry.get("raw", ""))})
        is_light = _is_likely_light(name_blob, dps)
        item = {
            "id": cid,
            "cid": cid,
            "name": entry.get("name") or f"MOES Light {cid[-4:]}",
            "category": "light_rgb" if is_light else "unknown",
            "gateway_id": selected_hub,
            "hub_ip": selected_ip,
            "hub_version": str(selected_version),
            "online": online,
            "is_light": is_light,
            "dps": dps,
        }
        subdevices.append(item)
        if is_light:
            lights.append(item)

    if not lights:
        lights = list(subdevices)

    moes_cfg = get_setting("moes")
    moes_cfg["last_light_scan_at"] = utc_now()
    moes_cfg["hub_device_id"] = selected_hub
    moes_cfg["hub_ip"] = selected_ip
    moes_cfg["hub_mac"] = selected_mac
    moes_cfg["hub_version"] = str(selected_version)
    set_setting("moes", moes_cfg)

    append_event(
        "moes_light_discovery",
        {
            "selected_hub": selected_hub,
            "hub_ip": selected_ip,
            "hub_mac": selected_mac,
            "light_count": len(lights),
            "subdevice_count": len(subdevices),
            "local_only": True,
        },
    )
    return {
        "selected_hub_device_id": selected_hub,
        "selected_hub_ip": selected_ip,
        "selected_hub_mac": selected_mac,
        "selected_hub_version": str(selected_version),
        "hubs": hubs,
        "lights": lights,
        "subdevices": subdevices,
        "local_only": True,
        "subdev_raw": subdev_raw,
    }


def send_bhubw_light_command(metadata: dict[str, Any], command: dict[str, Any]) -> dict[str, Any]:
    selected_hub, selected_ip, selected_key, selected_version, selected_mac = _resolve_hub_inputs(
        hub_device_id=str(metadata.get("hub_device_id", "")).strip(),
        hub_ip=str(metadata.get("hub_ip", "")).strip(),
        hub_mac=str(metadata.get("hub_mac", "")).strip(),
        hub_local_key=str(metadata.get("hub_local_key", "")).strip(),
        hub_version=str(metadata.get("hub_version", "")).strip(),
    )
    cid = str(
        metadata.get("moes_cid", "")
        or metadata.get("cid", "")
        or metadata.get("tuya_device_id", "")
    ).strip()
    if not cid:
        raise ValueError("MOES light is missing cid/tuya_device_id metadata")

    parent = _create_hub_device(
        hub_id=selected_hub,
        hub_ip=selected_ip,
        local_key=selected_key,
        version=selected_version,
    )
    child = _create_child_device(parent, cid)

    state = str(command.get("state", "")).strip().lower()
    payload = command.get("payload") if isinstance(command.get("payload"), dict) else {}
    if not payload:
        if isinstance(command.get("dps"), dict):
            payload["dps"] = command.get("dps")
        if command.get("brightness") is not None:
            payload["brightness"] = command.get("brightness")
    value = command.get("value")

    status = child.status()
    dps = _extract_dps(status)
    onoff_dp = _find_onoff_dp(dps)

    if state in ("on", "off", "toggle"):
        target = state == "on"
        if state == "toggle":
            current = dps.get(str(onoff_dp))
            target = not bool(current)
        result = child.set_status(target, switch=onoff_dp)
        return {
            "ok": True,
            "provider": "moes_bhubw",
            "mode": "local_lan",
            "result": result,
            "resolved": {
                "hub_id": selected_hub,
                "hub_ip": selected_ip,
                "hub_mac": selected_mac,
                "hub_version": str(selected_version),
                "cid": cid,
            },
        }

    if state == "set" and isinstance(payload.get("dps"), dict):
        result = child.set_multiple_values(payload.get("dps", {}))
        return {
            "ok": True,
            "provider": "moes_bhubw",
            "mode": "local_lan",
            "result": result,
            "resolved": {
                "hub_id": selected_hub,
                "hub_ip": selected_ip,
                "hub_mac": selected_mac,
                "hub_version": str(selected_version),
                "cid": cid,
            },
        }

    brightness_dp = _find_brightness_dp(dps)
    brightness_value = value if value is not None else payload.get("brightness")
    if state == "set" and brightness_dp is not None and brightness_value is not None:
        target = int(brightness_value)
        current = dps.get(str(brightness_dp))
        if isinstance(current, int) and current > 100 and 0 <= target <= 100:
            target = max(10, min(1000, target * 10))
        result = child.set_value(brightness_dp, target)
        return {
            "ok": True,
            "provider": "moes_bhubw",
            "mode": "local_lan",
            "result": result,
            "resolved": {
                "hub_id": selected_hub,
                "hub_ip": selected_ip,
                "hub_mac": selected_mac,
                "hub_version": str(selected_version),
                "cid": cid,
                "brightness_dp": brightness_dp,
            },
        }

    raise ValueError(f"Unsupported MOES command state '{state}' for local light control")


def get_bhubw_light_status(metadata: dict[str, Any]) -> dict[str, Any]:
    selected_hub, selected_ip, selected_key, selected_version, selected_mac = _resolve_hub_inputs(
        hub_device_id=str(metadata.get("hub_device_id", "")).strip(),
        hub_ip=str(metadata.get("hub_ip", "")).strip(),
        hub_mac=str(metadata.get("hub_mac", "")).strip(),
        hub_local_key=str(metadata.get("hub_local_key", "")).strip(),
        hub_version=str(metadata.get("hub_version", "")).strip(),
    )
    cid = str(
        metadata.get("moes_cid", "")
        or metadata.get("cid", "")
        or metadata.get("tuya_device_id", "")
    ).strip()
    if not cid:
        raise ValueError("MOES light is missing cid/tuya_device_id metadata")

    parent = _create_hub_device(
        hub_id=selected_hub,
        hub_ip=selected_ip,
        local_key=selected_key,
        version=selected_version,
    )
    child = _create_child_device(parent, cid)
    raw = child.status()
    dps = _extract_dps(raw)
    onoff_dp = _find_onoff_dp(dps)
    outputs: dict[str, Any] = {f"dp_{k}": v for k, v in dps.items() if isinstance(v, (bool, int, float, str))}
    outputs["light"] = bool(dps.get(str(onoff_dp)))
    outputs["power"] = outputs["light"]
    return {
        "ok": True,
        "provider": "moes_bhubw",
        "mode": "local_lan",
        "device_id": cid,
        "hub_id": selected_hub,
        "hub_ip": selected_ip,
        "hub_mac": selected_mac,
        "hub_version": str(selected_version),
        "outputs": outputs,
        "dps": dps,
        "raw": raw,
    }
