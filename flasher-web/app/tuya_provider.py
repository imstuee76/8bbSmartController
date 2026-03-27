from __future__ import annotations

import colorsys
import time
import uuid
from typing import Any

from .security import decrypt_secret
from .storage import append_event, get_setting


class TuyaCloudFallbackRequiredError(ValueError):
    def __init__(self, message: str, *, detail: dict[str, Any] | None = None):
        super().__init__(message)
        self.detail = detail or {}


def _parse_version(value: Any, fallback: float = 3.3) -> float:
    try:
        return float(str(value).strip())
    except Exception:
        return fallback


def _version_candidates(metadata: dict[str, Any]) -> list[float]:
    raw_version = str(metadata.get("tuya_version", metadata.get("version", ""))).strip()
    candidates: list[float] = []
    if raw_version:
        candidates.append(_parse_version(raw_version, fallback=3.3))
    else:
        candidates.extend([3.3, 3.4])
    if 3.4 not in candidates:
        candidates.append(3.4)
    return candidates


def _tuya_raw_error(raw: Any) -> str:
    if not isinstance(raw, dict):
        return ""
    err = str(raw.get("Err", "")).strip()
    message = str(raw.get("Error", "")).strip()
    if err or message:
        return f"{err}: {message}".strip(": ").strip()
    return ""


def _local_error_allows_cloud_fallback(error_text: str) -> bool:
    text = str(error_text or "").strip().lower()
    if not text:
        return False
    return any(
        token in text
        for token in (
            "device unreachable",
            "network error",
            "timed out",
            "timeout",
            "connection reset",
            "connection refused",
            "connection aborted",
            "connection closed",
            "no route to host",
            "host unreachable",
        )
    )


def _is_light_device(metadata: dict[str, Any]) -> bool:
    device_type = str(metadata.get("device_type", "")).strip().lower()
    blob = " ".join(
        str(metadata.get(key, "")).strip().lower()
        for key in ("device_type", "name", "device_name", "source_name", "product_name", "category")
    )
    return (
        device_type.startswith("light_")
        or "rgb" in blob
        or "light" in blob
        or "bulb" in blob
        or "lamp" in blob
        or "dimmer" in blob
    )


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


def _outputs_from_dps(dps: dict[str, Any]) -> dict[str, Any]:
    outputs: dict[str, Any] = {}
    for key, value in dps.items():
        if isinstance(value, (bool, int, float, str)):
            outputs[f"dp_{key}"] = value
    for key in ("1", "20", "101"):
        if key in dps and isinstance(dps[key], bool):
            outputs["power"] = bool(dps[key])
            outputs["light"] = bool(dps[key])
            break
    return outputs


def _onoff_dp_from_dps(dps: dict[str, Any]) -> str | int:
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


def _default_onoff_dp(metadata: dict[str, Any]) -> str | int:
    if _is_light_device(metadata):
        return 20
    return 1


def _brightness_dp_from_dps(dps: dict[str, Any]) -> str | int | None:
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


def _clamp_pct(value: Any, fallback: int = 100) -> int:
    try:
        out = int(float(value))
    except Exception:
        return fallback
    return max(0, min(100, out))


def _rgb_component(value: Any) -> int:
    try:
        numeric = float(value)
    except Exception:
        return 0
    if numeric <= 1:
        numeric *= 255
    elif numeric <= 100:
        numeric = numeric * 2.55
    return max(0, min(255, int(round(numeric))))


def _rgb_payload(payload: dict[str, Any]) -> tuple[int, int, int] | None:
    if not isinstance(payload, dict):
        return None
    if not any(key in payload for key in ("r", "g", "b")):
        return None
    return (
        _rgb_component(payload.get("r", 0)),
        _rgb_component(payload.get("g", 0)),
        _rgb_component(payload.get("b", 0)),
    )


def _rgb_to_tuya_hsv_json(r: int, g: int, b: int, brightness_pct: int | None = None) -> str:
    r_f, g_f, b_f = (max(0, min(255, c)) / 255.0 for c in (r, g, b))
    h, s, v = colorsys.rgb_to_hsv(r_f, g_f, b_f)
    out_v = int(round(v * 1000))
    if brightness_pct is not None:
        out_v = max(0, min(1000, int(round(max(0, min(100, brightness_pct)) * 10))))
    return '{{"h":{h},"s":{s},"v":{v}}}'.format(
        h=max(0, min(360, int(round(h * 360)))),
        s=max(0, min(1000, int(round(s * 1000)))),
        v=max(0, min(1000, out_v)),
    )


def _pick_cloud_color_code(cloud_values: dict[str, Any], functions: list[dict[str, Any]]) -> str | None:
    candidates = ["colour_data_v2", "colour_data", "color_data_v2", "color_data"]
    for c in candidates:
        if c in cloud_values:
            return c
    fn_codes = {str(f.get("code", "")).strip() for f in functions}
    for c in candidates:
        if c in fn_codes:
            return c
    return None


def _pick_cloud_mode_code(cloud_values: dict[str, Any], functions: list[dict[str, Any]]) -> str | None:
    candidates = ["work_mode", "work_mode_1", "light_mode"]
    for c in candidates:
        if c in cloud_values:
            return c
    fn_codes = {str(f.get("code", "")).strip() for f in functions}
    for c in candidates:
        if c in fn_codes:
            return c
    return None


def _pick_cloud_scene_code(cloud_values: dict[str, Any], functions: list[dict[str, Any]]) -> str | None:
    candidates = ["scene_data_v2", "scene_data"]
    for c in candidates:
        if c in cloud_values:
            return c
    fn_codes = {str(f.get("code", "")).strip() for f in functions}
    for c in candidates:
        if c in fn_codes:
            return c
    return None


def _channel_to_dp_hint(channel: str) -> int | None:
    text = str(channel or "").strip().lower()
    if not text:
        return None
    if text.startswith("dp_"):
        try:
            return int(text.split("_", 1)[1])
        except Exception:
            return None
    import re

    match = re.search(r"(relay|switch|channel|out|gang)[_-]?(\d+)$", text)
    if not match:
        return None
    try:
        return int(match.group(2))
    except Exception:
        return None


def _is_explicit_switch_channel(channel: str) -> bool:
    text = str(channel or "").strip().lower()
    if not text:
        return False
    if text.startswith("dp_"):
        return True
    import re

    return bool(re.search(r"(relay|switch|channel|out|gang)[_-]?\d+$", text))


def _resolve_local_toggle_dp(channel: str, dps: dict[str, Any]) -> str | int:
    fallback = _onoff_dp_from_dps(dps)
    dp_hint = _channel_to_dp_hint(channel)
    if dp_hint is None:
        return fallback
    if str(dp_hint) in dps and isinstance(dps[str(dp_hint)], bool):
        return dp_hint
    if str(dp_hint) in dps:
        return dp_hint
    return fallback


def _resolve_cloud_power_code(channel: str, cloud_values: dict[str, Any], functions: list[dict[str, Any]]) -> str | None:
    requested = str(channel or "").strip().lower()
    fn_codes = {str(f.get("code", "")).strip() for f in functions}
    if requested:
        if requested in cloud_values or requested in fn_codes:
            return requested
        dp_hint = _channel_to_dp_hint(requested)
        if dp_hint is not None:
            switch_code = f"switch_{dp_hint}"
            if switch_code in cloud_values or switch_code in fn_codes:
                return switch_code
    return _pick_cloud_power_code(cloud_values, functions)


def _cloud_client() -> Any:
    tuya_cfg = get_setting("tuya")
    region = str(tuya_cfg.get("cloud_region", "")).strip()
    client_id = str(tuya_cfg.get("client_id", "")).strip()
    client_secret = decrypt_secret(str(tuya_cfg.get("client_secret", ""))).strip()
    api_device_id = str(tuya_cfg.get("api_device_id", "")).strip()
    if not region or not client_id or not client_secret:
        raise ValueError("Tuya cloud credentials are not configured")
    try:
        import tinytuya  # type: ignore
    except Exception as exc:
        raise ValueError(f"tinytuya not installed: {exc}") from exc
    return tinytuya.Cloud(  # type: ignore[attr-defined]
        apiRegion=region,
        apiKey=client_id,
        apiSecret=client_secret,
        apiDeviceID=api_device_id,
    )


def _local_device(
    metadata: dict[str, Any],
    *,
    version_override: float | None = None,
    socket_timeout: float = 3.0,
    retry_limit: int = 1,
) -> Any:
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    ip = str(metadata.get("tuya_ip", "")).strip() or str(metadata.get("ip", "")).strip() or str(metadata.get("host", "")).strip()
    local_key = str(metadata.get("tuya_local_key", "")).strip() or str(metadata.get("local_key", "")).strip()
    version = version_override if version_override is not None else _parse_version(metadata.get("tuya_version", metadata.get("version", "3.3")), fallback=3.3)

    if not dev_id or not ip or not local_key:
        raise ValueError("Tuya local control requires tuya_device_id + tuya_ip + tuya_local_key")

    try:
        import tinytuya  # type: ignore
    except Exception as exc:
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    dev = tinytuya.Device(dev_id, ip, local_key)  # type: ignore[attr-defined]
    dev.set_version(version)
    dev.set_socketPersistent(False)
    if hasattr(dev, "set_socketTimeout"):
        try:
            dev.set_socketTimeout(float(socket_timeout))
        except Exception:
            pass
    if hasattr(dev, "set_socketRetryLimit"):
        try:
            dev.set_socketRetryLimit(int(retry_limit))
        except Exception:
            pass
    return dev, dev_id, ip, version


def _local_bulb_device(
    metadata: dict[str, Any],
    *,
    version_override: float | None = None,
    socket_timeout: float = 3.0,
    retry_limit: int = 1,
) -> Any:
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    ip = str(metadata.get("tuya_ip", "")).strip() or str(metadata.get("ip", "")).strip() or str(metadata.get("host", "")).strip()
    local_key = str(metadata.get("tuya_local_key", "")).strip() or str(metadata.get("local_key", "")).strip()
    version = version_override if version_override is not None else _parse_version(metadata.get("tuya_version", metadata.get("version", "3.3")), fallback=3.3)

    if not dev_id or not ip or not local_key:
        raise ValueError("Tuya local control requires tuya_device_id + tuya_ip + tuya_local_key")

    try:
        import tinytuya  # type: ignore
    except Exception as exc:
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    dev = tinytuya.BulbDevice(dev_id, ip, local_key)  # type: ignore[attr-defined]
    dev.set_version(version)
    dev.set_socketPersistent(False)
    if hasattr(dev, "set_socketTimeout"):
        try:
            dev.set_socketTimeout(float(socket_timeout))
        except Exception:
            pass
    if hasattr(dev, "set_socketRetryLimit"):
        try:
            dev.set_socketRetryLimit(int(retry_limit))
        except Exception:
            pass
    return dev, dev_id, ip, version


def _cloud_status_values(items: list[dict[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for item in items:
        code = str(item.get("code", "")).strip()
        if not code:
            continue
        out[code] = item.get("value")
    return out


def _pick_cloud_power_code(cloud_values: dict[str, Any], functions: list[dict[str, Any]]) -> str | None:
    candidates = ["switch_led", "switch_1", "switch", "light"]
    for c in candidates:
        if c in cloud_values:
            return c
    fn_codes = {str(f.get("code", "")).strip() for f in functions}
    for c in candidates:
        if c in fn_codes:
            return c
    return None


def _has_complete_local_metadata(metadata: dict[str, Any]) -> bool:
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    ip = str(metadata.get("tuya_ip", "")).strip() or str(metadata.get("ip", "")).strip() or str(metadata.get("host", "")).strip()
    local_key = str(metadata.get("tuya_local_key", "")).strip() or str(metadata.get("local_key", "")).strip()
    return bool(dev_id and ip and local_key)


def _enrich_local_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
    try:
        from .integrations import _get_file_value, _load_tuya_devices_file, _tuya_devices_file_indexes
    except Exception:
        return dict(metadata)

    rows, _ = _load_tuya_devices_file()
    if not rows:
        return dict(metadata)

    by_id, by_mac, by_ip = _tuya_devices_file_indexes(rows)
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    mac = str(metadata.get("mac", "")).strip().lower()
    ip = str(metadata.get("tuya_ip", "")).strip() or str(metadata.get("ip", "")).strip() or str(metadata.get("host", "")).strip()
    name = str(metadata.get("name", "")).strip().lower() or str(metadata.get("device_name", "")).strip().lower()

    match = by_id.get(dev_id) if dev_id else None
    if not match and mac:
        match = by_mac.get(mac)
    if not match and ip:
        match = by_ip.get(ip)
    if not match and name:
        for row in rows:
            if not isinstance(row, dict):
                continue
            row_name = str(row.get("name", "")).strip().lower()
            if row_name and row_name == name:
                match = row
                break
    if not match:
        return dict(metadata)

    enriched = dict(metadata)
    repaired_id = _get_file_value(match, "id", "gwId", "dev_id", "tuya_device_id")
    repaired_ip = _get_file_value(match, "ip", "local_ip")
    repaired_key = _get_file_value(match, "local_key", "key")
    repaired_version = _get_file_value(match, "version")
    repaired_product_key = _get_file_value(match, "product_key", "productKey")

    def assign_if_blank(*keys: str, value: str) -> None:
        if not value:
            return
        for key in keys:
            current = str(enriched.get(key, "")).strip()
            if not current:
                enriched[key] = value

    if repaired_id:
        assign_if_blank("tuya_device_id", "id", value=repaired_id)
    if repaired_ip:
        assign_if_blank("tuya_ip", "ip", "host", value=repaired_ip)
    if repaired_key:
        assign_if_blank("tuya_local_key", "local_key", value=repaired_key)
    if repaired_version:
        assign_if_blank("tuya_version", "version", value=repaired_version)
    if repaired_product_key:
        assign_if_blank("tuya_product_key", "product_key", value=repaired_product_key)
    return enriched


def _pick_cloud_brightness_code(cloud_values: dict[str, Any], functions: list[dict[str, Any]]) -> str | None:
    candidates = ["bright_value_v2", "bright_value_1", "bright_value", "brightness"]
    for c in candidates:
        if c in cloud_values:
            return c
    fn_codes = {str(f.get("code", "")).strip() for f in functions}
    for c in candidates:
        if c in fn_codes:
            return c
    return None


def get_tuya_device_status(metadata: dict[str, Any], quick: bool = False) -> dict[str, Any]:
    metadata = _enrich_local_metadata(metadata)
    provider = str(metadata.get("provider", "tuya_local")).strip().lower()
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    local_error = ""

    if provider in ("tuya_local", "tuya"):
        raw_version = str(metadata.get("tuya_version", metadata.get("version", ""))).strip()
        last_exc: Exception | None = None
        for version_candidate in _version_candidates(metadata):
            try:
                dev, local_id, ip, version = _local_device(
                    metadata,
                    version_override=version_candidate,
                    socket_timeout=1.0 if quick else 3.0,
                    retry_limit=0 if quick else 1,
                )
                raw = dev.status()
                dps = _extract_dps(raw)
                raw_error = _tuya_raw_error(raw)
                if raw_error and not dps and (not raw_version):
                    local_error = raw_error
                    continue
                return {
                    "ok": True,
                    "provider": "tuya_local",
                    "mode": "local_lan",
                    "device_id": local_id,
                    "ip": ip,
                    "version": str(version),
                    "outputs": _outputs_from_dps(dps),
                    "dps": dps,
                    "raw": raw,
                    "metadata_patch": {"tuya_version": str(version), "version": str(version)} if not raw_version else {},
                }
            except Exception as exc:
                last_exc = exc
                local_error = str(exc)
        if last_exc is not None and quick:
            raise ValueError(f"Tuya quick local status failed: {local_error}") from last_exc

    if dev_id:
        try:
            cloud = _cloud_client()
        except Exception as exc:
            if local_error:
                raise ValueError(f"Tuya local failed: {local_error}; cloud unavailable: {exc}") from exc
            raise
        status_res = cloud.getstatus(dev_id)
        if not isinstance(status_res, dict):
            raise ValueError("Unexpected Tuya cloud status response")
        if not status_res.get("success", False):
            detail = status_res.get("msg") or status_res.get("code") or status_res
            if local_error:
                raise ValueError(f"Tuya local failed: {local_error}; cloud failed: {detail}")
            raise ValueError(f"Tuya cloud status failed: {detail}")
        items = status_res.get("result", [])
        cloud_values = _cloud_status_values(items if isinstance(items, list) else [])
        outputs = {k: v for k, v in cloud_values.items() if isinstance(v, (bool, int, float, str))}
        if "switch_led" in cloud_values:
            outputs["power"] = bool(cloud_values["switch_led"])
            outputs["light"] = bool(cloud_values["switch_led"])
        elif "switch_1" in cloud_values:
            outputs["power"] = bool(cloud_values["switch_1"])
            outputs["light"] = bool(cloud_values["switch_1"])
        elif "switch" in cloud_values:
            outputs["power"] = bool(cloud_values["switch"])
            outputs["light"] = bool(cloud_values["switch"])
        provider_name = "tuya_cloud"
        mode_name = "cloud"
        fallback_via_cloud = False
        if provider == "tuya_local":
            provider_name = "tuya_local"
            mode_name = "local_lan"
            fallback_via_cloud = True
        return {
            "ok": True,
            "provider": provider_name,
            "mode": mode_name,
            "device_id": dev_id,
            "outputs": outputs,
            "cloud_values": cloud_values,
            "raw": status_res,
            "local_error": local_error,
            "fallback_via_cloud": fallback_via_cloud,
        }

    if local_error:
        raise ValueError(f"Tuya local status failed: {local_error}")
    raise ValueError("Tuya metadata missing tuya_device_id")


def send_tuya_device_command(metadata: dict[str, Any], command: dict[str, Any]) -> dict[str, Any]:
    started_at = time.perf_counter()
    metadata = _enrich_local_metadata(metadata)
    provider = str(metadata.get("provider", "tuya_local")).strip().lower()
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    state = str(command.get("state", "")).strip().lower()
    channel = str(command.get("channel", "")).strip().lower()
    payload = command.get("payload") if isinstance(command.get("payload"), dict) else {}
    allow_cloud_fallback = bool(payload.get("allow_cloud_fallback", True))
    trace_id = str(payload.get("trace_id", "")).strip() or f"tuya-{uuid.uuid4().hex[:12]}"
    value = command.get("value")
    brightness_value = value if value is not None else payload.get("brightness")
    rgb = _rgb_payload(payload)
    requested_scene = payload.get("scene", payload.get("effect"))
    requested_mode = str(payload.get("mode", "")).strip().lower()
    explicit_switch_channel = _is_explicit_switch_channel(channel)
    light_channel = (
        not explicit_switch_channel
        and (
            channel in ("light", "rgb", "rgbw", "dimmer", "brightness", "scene", "effect")
            or _is_light_device(metadata)
        )
    )
    trace: dict[str, Any] = {
        "trace_id": trace_id,
        "provider": provider,
        "device_name": str(metadata.get("device_name", metadata.get("name", ""))).strip(),
        "tuya_device_id": dev_id,
        "state": state,
        "channel": channel,
        "allow_cloud_fallback": allow_cloud_fallback,
        "light_channel": light_channel,
        "explicit_switch_channel": explicit_switch_channel,
        "local_ready": False,
        "local_attempts": [],
        "cloud_attempted": False,
    }

    # Local path first for local/dual devices.
    local_error = ""
    local_ready = _has_complete_local_metadata(metadata)
    trace["local_ready"] = local_ready
    trace["local_ip"] = str(metadata.get("tuya_ip", metadata.get("ip", metadata.get("host", "")))).strip()
    if provider in ("tuya_local", "tuya") and local_ready:
        raw_version = str(metadata.get("tuya_version", metadata.get("version", ""))).strip()
        last_exc: Exception | None = None
        for version_candidate in _version_candidates(metadata):
            attempt_started = time.perf_counter()
            attempt_info: dict[str, Any] = {
                "version_candidate": str(version_candidate),
                "used_status_lookup": False,
            }
            try:
                use_bulb = _is_light_device(metadata) and state in ("on", "off")
                attempt_info["path"] = "local_bulb" if use_bulb else "local_device"
                if use_bulb:
                    dev, local_id, ip, version = _local_bulb_device(
                        metadata,
                        version_override=version_candidate,
                        socket_timeout=0.9,
                        retry_limit=0,
                    )
                    raw = dev.turn_on() if state == "on" else dev.turn_off()
                else:
                    dev, local_id, ip, version = _local_device(
                        metadata,
                        version_override=version_candidate,
                        socket_timeout=0.9,
                        retry_limit=0,
                    )
                    status: dict[str, Any] | None = None
                    dps: dict[str, Any] = {}
                    dp_hint = _channel_to_dp_hint(channel)
                    if state in ("on", "off") and dp_hint is not None:
                        onoff_dp = dp_hint
                    elif state in ("on", "off") and _is_light_device(metadata):
                        onoff_dp = _default_onoff_dp(metadata)
                    else:
                        attempt_info["used_status_lookup"] = True
                        status = dev.status()
                        dps = _extract_dps(status)
                        onoff_dp = _resolve_local_toggle_dp(channel, dps)
                        if not dps and _is_light_device(metadata):
                            onoff_dp = _default_onoff_dp(metadata)

                    if light_channel:
                        bulb, local_id, ip, version = _local_bulb_device(
                            metadata,
                            version_override=version_candidate,
                            socket_timeout=0.9,
                            retry_limit=0,
                        )
                        if state in ("on", "off"):
                            raw = bulb.turn_on() if state == "on" else bulb.turn_off()
                        elif state in ("scene", "effect") or requested_scene is not None:
                            scene_value = requested_scene if requested_scene is not None else payload.get("value", "1")
                            raw = bulb.set_mode("scene")
                            scene_raw = bulb.set_scene(scene_value)
                            if scene_raw is not None:
                                raw = scene_raw
                        elif state == "set" and rgb is not None:
                            raw = bulb.set_mode("colour")
                            colour_raw = bulb.set_colour(*rgb)
                            if colour_raw is not None:
                                raw = colour_raw
                            if brightness_value is not None:
                                bright_raw = bulb.set_brightness_percentage(_clamp_pct(brightness_value, fallback=100))
                                if bright_raw is not None:
                                    raw = bright_raw
                        elif state == "set" and (requested_mode == "white" or payload.get("white") is not None):
                            white_level = _clamp_pct(payload.get("white", brightness_value), fallback=100)
                            color_temp = _clamp_pct(payload.get("color_temp", payload.get("colour_temp", 0)), fallback=0)
                            raw = bulb.set_mode("white")
                            white_raw = bulb.set_white_percentage(white_level, color_temp)
                            if white_raw is not None:
                                raw = white_raw
                        elif state == "set" and brightness_value is not None:
                            raw = bulb.set_brightness_percentage(_clamp_pct(brightness_value, fallback=100))
                        else:
                            raise ValueError(f"Unsupported Tuya local light state '{state}'")
                    elif state in ("on", "off", "toggle"):
                        target = state == "on"
                        if state == "toggle":
                            target = not bool(dps.get(str(onoff_dp)))
                        attempt_info["resolved_dp"] = onoff_dp
                        raw = dev.set_status(target, switch=onoff_dp)
                    elif state == "set" and isinstance(payload.get("dps"), dict):
                        raw = dev.set_multiple_values(payload.get("dps", {}))
                    else:
                        brightness_dp = _brightness_dp_from_dps(dps)
                        if state == "set" and brightness_dp is not None and brightness_value is not None:
                            target = int(brightness_value)
                            current = dps.get(str(brightness_dp))
                            if isinstance(current, int) and current > 100 and 0 <= target <= 100:
                                target = max(10, min(1000, target * 10))
                            raw = dev.set_value(brightness_dp, target)
                        else:
                            raise ValueError(f"Unsupported Tuya local state '{state}'")

                raw_error = _tuya_raw_error(raw)
                if raw_error and not raw_version:
                    local_error = raw_error
                    attempt_info["error"] = raw_error
                    attempt_info["elapsed_ms"] = round((time.perf_counter() - attempt_started) * 1000, 1)
                    trace["local_attempts"].append(attempt_info)
                    continue
                if raw_error:
                    raise ValueError(raw_error)
                attempt_info["elapsed_ms"] = round((time.perf_counter() - attempt_started) * 1000, 1)
                attempt_info["ok"] = True
                attempt_info["device_id"] = local_id
                attempt_info["ip"] = ip
                trace["local_attempts"].append(attempt_info)
                trace["result_provider"] = "tuya_local"
                trace["result_mode"] = "local_lan"
                trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
                append_event("tuya_command_trace", trace)
                response: dict[str, Any] = {
                    "ok": True,
                    "provider": "tuya_local",
                    "mode": "local_lan",
                    "device_id": local_id,
                    "ip": ip,
                    "version": str(version),
                    "result": raw,
                    "trace_id": trace_id,
                    "trace_total_ms": trace["total_ms"],
                }
                if not raw_version:
                    response["metadata_patch"] = {"tuya_version": str(version), "version": str(version)}
                return response
            except Exception as exc:
                last_exc = exc
                local_error = str(exc)
                attempt_info["error"] = local_error
                attempt_info["elapsed_ms"] = round((time.perf_counter() - attempt_started) * 1000, 1)
                trace["local_attempts"].append(attempt_info)
        if provider == "tuya_local" and not _local_error_allows_cloud_fallback(local_error):
            detail = local_error or "Local Tuya command failed"
            trace["result_provider"] = "tuya_local"
            trace["result_mode"] = "local_lan"
            trace["error"] = detail
            trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
            append_event("tuya_command_trace", trace)
            raise ValueError(f"Tuya local command failed: {detail}") from last_exc
    elif provider == "tuya_local":
        local_error = "Tuya local control requires tuya_device_id + tuya_ip + tuya_local_key"

    if provider == "tuya_local" and local_error and not allow_cloud_fallback and _local_error_allows_cloud_fallback(local_error):
        trace["result_provider"] = "tuya_local"
        trace["result_mode"] = "local_lan"
        trace["error"] = local_error
        trace["fallback_available"] = True
        trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
        append_event("tuya_command_trace", trace)
        raise TuyaCloudFallbackRequiredError(
            "Local Tuya control failed, but cloud fallback is available",
            detail={
                "fallback_available": True,
                "provider": provider,
                "device_id": dev_id,
                "local_error": local_error,
                "mode": "local_lan",
            },
        )

    # Cloud command path.
    if not dev_id:
        if local_error:
            trace["error"] = local_error
            trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
            append_event("tuya_command_trace", trace)
            raise ValueError(f"Tuya local command failed: {local_error}")
        trace["error"] = "Tuya metadata missing tuya_device_id"
        trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
        append_event("tuya_command_trace", trace)
        raise ValueError("Tuya metadata missing tuya_device_id")

    try:
        trace["cloud_attempted"] = True
        cloud_started = time.perf_counter()
        cloud = _cloud_client()
    except Exception as exc:
        if local_error:
            trace["error"] = f"{local_error}; cloud unavailable: {exc}"
            trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
            append_event("tuya_command_trace", trace)
            raise ValueError(f"Tuya local failed: {local_error}; cloud unavailable: {exc}") from exc
        trace["error"] = str(exc)
        trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
        append_event("tuya_command_trace", trace)
        raise
    status_res = cloud.getstatus(dev_id)
    trace["cloud_status_ms"] = round((time.perf_counter() - cloud_started) * 1000, 1)
    status_items = status_res.get("result", []) if isinstance(status_res, dict) else []
    status_values = _cloud_status_values(status_items if isinstance(status_items, list) else [])
    fn_started = time.perf_counter()
    fn_res = cloud.getfunctions(dev_id)
    trace["cloud_functions_ms"] = round((time.perf_counter() - fn_started) * 1000, 1)
    fn_items = fn_res.get("result", []) if isinstance(fn_res, dict) else []
    if isinstance(fn_items, list):
        functions = fn_items
    elif isinstance(fn_items, dict) and isinstance(fn_items.get("functions"), list):
        functions = fn_items.get("functions", [])
    else:
        functions = []

    commands: list[dict[str, Any]] = []
    if isinstance(payload.get("commands"), list):
        commands = [c for c in payload.get("commands", []) if isinstance(c, dict)]
    elif light_channel and (state in ("scene", "effect") or requested_scene is not None):
        mode_code = _pick_cloud_mode_code(status_values, functions)
        scene_code = _pick_cloud_scene_code(status_values, functions)
        scene_value = str(requested_scene if requested_scene is not None else "1")
        if mode_code:
            commands.append({"code": mode_code, "value": "scene"})
        if scene_code:
            commands.append({"code": scene_code, "value": scene_value})
    elif light_channel and state == "set" and rgb is not None:
        mode_code = _pick_cloud_mode_code(status_values, functions)
        color_code = _pick_cloud_color_code(status_values, functions)
        if mode_code:
            commands.append({"code": mode_code, "value": "colour"})
        if color_code:
            commands.append({"code": color_code, "value": _rgb_to_tuya_hsv_json(*rgb, brightness_pct=_clamp_pct(brightness_value, fallback=100) if brightness_value is not None else None)})
        elif brightness_value is not None:
            brightness_code = _pick_cloud_brightness_code(status_values, functions)
            if brightness_code is not None:
                commands.append({"code": brightness_code, "value": int(brightness_value)})
    elif light_channel and state == "set" and (requested_mode == "white" or payload.get("white") is not None):
        mode_code = _pick_cloud_mode_code(status_values, functions)
        brightness_code = _pick_cloud_brightness_code(status_values, functions)
        if mode_code:
            commands.append({"code": mode_code, "value": "white"})
        if brightness_code is not None:
            commands.append({"code": brightness_code, "value": _clamp_pct(payload.get("white", brightness_value), fallback=100)})
    elif light_channel and state == "set" and brightness_value is not None:
        brightness_code = _pick_cloud_brightness_code(status_values, functions)
        if brightness_code is not None:
            commands.append({"code": brightness_code, "value": _clamp_pct(brightness_value, fallback=100)})
    elif state in ("on", "off", "toggle"):
        power_code = _resolve_cloud_power_code(channel, status_values, functions)
        if not power_code:
            raise ValueError("Could not resolve Tuya cloud power code")
        target = state == "on"
        if state == "toggle":
            target = not bool(status_values.get(power_code))
        commands = [{"code": power_code, "value": target}]
    elif state == "set":
        if isinstance(payload.get("code"), str):
            commands = [{"code": payload.get("code"), "value": payload.get("value")}]
        else:
            brightness_code = _pick_cloud_brightness_code(status_values, functions)
            if brightness_code is not None and brightness_value is not None:
                commands = [{"code": brightness_code, "value": int(brightness_value)}]

    if not commands:
        detail = f"state={state}, payload_keys={list(payload.keys()) if isinstance(payload, dict) else []}"
        if local_error:
            raise ValueError(f"Tuya local failed: {local_error}; could not build cloud command ({detail})")
        raise ValueError(f"Could not build Tuya cloud command ({detail})")

    body = {"commands": commands}
    send_started = time.perf_counter()
    result = cloud.sendcommand(dev_id, body)
    trace["cloud_send_ms"] = round((time.perf_counter() - send_started) * 1000, 1)
    if not isinstance(result, dict):
        trace["error"] = "Unexpected Tuya cloud command response"
        trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
        append_event("tuya_command_trace", trace)
        raise ValueError("Unexpected Tuya cloud command response")
    if not result.get("success", False):
        detail = result.get("msg") or result.get("code") or result
        if local_error:
            trace["error"] = f"{local_error}; cloud command failed: {detail}"
            trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
            append_event("tuya_command_trace", trace)
            raise ValueError(f"Tuya local failed: {local_error}; cloud command failed: {detail}")
        trace["error"] = str(detail)
        trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
        append_event("tuya_command_trace", trace)
        raise ValueError(f"Tuya cloud command failed: {detail}")
    trace["result_provider"] = "tuya_cloud"
    trace["result_mode"] = "cloud"
    trace["total_ms"] = round((time.perf_counter() - started_at) * 1000, 1)
    append_event("tuya_command_trace", trace)
    return {
        "ok": True,
        "provider": "tuya_cloud",
        "mode": "cloud",
        "device_id": dev_id,
        "commands": commands,
        "result": result,
        "local_error": local_error,
        "trace_id": trace_id,
        "trace_total_ms": trace["total_ms"],
    }
