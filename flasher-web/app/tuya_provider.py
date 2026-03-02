from __future__ import annotations

from typing import Any

from .security import decrypt_secret
from .storage import get_setting


def _parse_version(value: Any, fallback: float = 3.3) -> float:
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
        apiDeviceID="",
    )


def _local_device(metadata: dict[str, Any]) -> Any:
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    ip = str(metadata.get("tuya_ip", "")).strip() or str(metadata.get("ip", "")).strip() or str(metadata.get("host", "")).strip()
    local_key = str(metadata.get("tuya_local_key", "")).strip() or str(metadata.get("local_key", "")).strip()
    version = _parse_version(metadata.get("tuya_version", metadata.get("version", "3.3")), fallback=3.3)

    if not dev_id or not ip or not local_key:
        raise ValueError("Tuya local control requires tuya_device_id + tuya_ip + tuya_local_key")

    try:
        import tinytuya  # type: ignore
    except Exception as exc:
        raise ValueError(f"tinytuya not installed: {exc}") from exc

    dev = tinytuya.Device(  # type: ignore[attr-defined]
        dev_id=dev_id,
        address=ip,
        local_key=local_key,
        version=version,
        persist=False,
    )
    dev.set_version(version)
    dev.set_socketPersistent(False)
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


def get_tuya_device_status(metadata: dict[str, Any]) -> dict[str, Any]:
    provider = str(metadata.get("provider", "tuya_local")).strip().lower()
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    local_error = ""

    if provider in ("tuya_local", "tuya"):
        try:
            dev, local_id, ip, version = _local_device(metadata)
            raw = dev.status()
            dps = _extract_dps(raw)
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
            }
        except Exception as exc:
            local_error = str(exc)
            if provider == "tuya_local":
                # local-first devices can still fall back to cloud by ID if creds exist
                pass

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
        return {
            "ok": True,
            "provider": "tuya_cloud",
            "mode": "cloud",
            "device_id": dev_id,
            "outputs": outputs,
            "cloud_values": cloud_values,
            "raw": status_res,
            "local_error": local_error,
        }

    if local_error:
        raise ValueError(f"Tuya local status failed: {local_error}")
    raise ValueError("Tuya metadata missing tuya_device_id")


def send_tuya_device_command(metadata: dict[str, Any], command: dict[str, Any]) -> dict[str, Any]:
    provider = str(metadata.get("provider", "tuya_local")).strip().lower()
    dev_id = str(metadata.get("tuya_device_id", "")).strip() or str(metadata.get("id", "")).strip()
    state = str(command.get("state", "")).strip().lower()
    channel = str(command.get("channel", "")).strip().lower()
    payload = command.get("payload") if isinstance(command.get("payload"), dict) else {}
    value = command.get("value")

    # Local path first for local/dual devices.
    local_error = ""
    if provider in ("tuya_local", "tuya"):
        try:
            dev, local_id, ip, version = _local_device(metadata)
            status = dev.status()
            dps = _extract_dps(status)
            onoff_dp = _resolve_local_toggle_dp(channel, dps)

            if state in ("on", "off", "toggle"):
                target = state == "on"
                if state == "toggle":
                    target = not bool(dps.get(str(onoff_dp)))
                raw = dev.set_status(target, switch=onoff_dp)
                return {
                    "ok": True,
                    "provider": "tuya_local",
                    "mode": "local_lan",
                    "device_id": local_id,
                    "ip": ip,
                    "version": str(version),
                    "result": raw,
                }

            if state == "set" and isinstance(payload.get("dps"), dict):
                raw = dev.set_multiple_values(payload.get("dps", {}))
                return {
                    "ok": True,
                    "provider": "tuya_local",
                    "mode": "local_lan",
                    "device_id": local_id,
                    "ip": ip,
                    "version": str(version),
                    "result": raw,
                }

            brightness_dp = _brightness_dp_from_dps(dps)
            brightness_value = value if value is not None else payload.get("brightness")
            if state == "set" and brightness_dp is not None and brightness_value is not None:
                target = int(brightness_value)
                current = dps.get(str(brightness_dp))
                if isinstance(current, int) and current > 100 and 0 <= target <= 100:
                    target = max(10, min(1000, target * 10))
                raw = dev.set_value(brightness_dp, target)
                return {
                    "ok": True,
                    "provider": "tuya_local",
                    "mode": "local_lan",
                    "device_id": local_id,
                    "ip": ip,
                    "version": str(version),
                    "result": raw,
                    "brightness_dp": brightness_dp,
                }
            raise ValueError(f"Unsupported Tuya local state '{state}'")
        except Exception as exc:
            local_error = str(exc)
            if provider == "tuya_local":
                # local devices can fall back to cloud control if credentials exist
                pass

    # Cloud command path.
    if not dev_id:
        if local_error:
            raise ValueError(f"Tuya local command failed: {local_error}")
        raise ValueError("Tuya metadata missing tuya_device_id")

    try:
        cloud = _cloud_client()
    except Exception as exc:
        if local_error:
            raise ValueError(f"Tuya local failed: {local_error}; cloud unavailable: {exc}") from exc
        raise
    status_res = cloud.getstatus(dev_id)
    status_items = status_res.get("result", []) if isinstance(status_res, dict) else []
    status_values = _cloud_status_values(status_items if isinstance(status_items, list) else [])
    fn_res = cloud.getfunctions(dev_id)
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
            brightness_value = value if value is not None else payload.get("brightness")
            if brightness_code is not None and brightness_value is not None:
                commands = [{"code": brightness_code, "value": int(brightness_value)}]

    if not commands:
        detail = f"state={state}, payload_keys={list(payload.keys()) if isinstance(payload, dict) else []}"
        if local_error:
            raise ValueError(f"Tuya local failed: {local_error}; could not build cloud command ({detail})")
        raise ValueError(f"Could not build Tuya cloud command ({detail})")

    body = {"commands": commands}
    result = cloud.sendcommand(dev_id, body)
    if not isinstance(result, dict):
        raise ValueError("Unexpected Tuya cloud command response")
    if not result.get("success", False):
        detail = result.get("msg") or result.get("code") or result
        if local_error:
            raise ValueError(f"Tuya local failed: {local_error}; cloud command failed: {detail}")
        raise ValueError(f"Tuya cloud command failed: {detail}")
    return {
        "ok": True,
        "provider": "tuya_cloud",
        "mode": "cloud",
        "device_id": dev_id,
        "commands": commands,
        "result": result,
        "local_error": local_error,
    }
