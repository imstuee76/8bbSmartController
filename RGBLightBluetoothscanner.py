#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import json
import os
import queue
import threading
import traceback
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import tkinter as tk
from tkinter import ttk, messagebox


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def day_stamp(now: datetime | None = None) -> str:
    dt = now or utc_now()
    return dt.strftime("%Y%m%d")


def iso_time(now: datetime | None = None) -> str:
    dt = now or utc_now()
    return dt.isoformat()


def hex_preview(data: bytes, limit: int = 32) -> str:
    if len(data) <= limit:
        return data.hex(" ")
    return f"{data[:limit].hex(' ')} ... ({len(data)} bytes)"


class SessionLogger:
    def __init__(self, app_root: Path) -> None:
        self.app_root = app_root
        self.data_dir = app_root / "data"
        self.session_id = f"ble-scanner-{utc_now().strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
        self.session_dir = self.data_dir / "logs" / "ble-scanner" / "sessions" / self.session_id
        self.session_dir.mkdir(parents=True, exist_ok=True)
        self.artifacts_dir = self.session_dir / "artifacts"
        self.artifacts_dir.mkdir(parents=True, exist_ok=True)
        day = day_stamp()
        self.activity_file = self.session_dir / f"activity-{day}.jsonl"
        self.error_file = self.session_dir / f"errors-{day}.jsonl"
        self.log("session_started", {"session_id": self.session_id, "app_root": str(self.app_root)})

    def log(self, event: str, payload: dict[str, Any] | None = None) -> None:
        row = {"time": iso_time(), "event": event, "payload": payload or {}}
        with self.activity_file.open("a", encoding="utf-8") as fp:
            fp.write(json.dumps(row, ensure_ascii=True) + "\n")

    def error(self, event: str, error: str, payload: dict[str, Any] | None = None) -> None:
        row = {
            "time": iso_time(),
            "event": event,
            "error": error,
            "payload": payload or {},
        }
        with self.error_file.open("a", encoding="utf-8") as fp:
            fp.write(json.dumps(row, ensure_ascii=True) + "\n")
        with self.activity_file.open("a", encoding="utf-8") as fp:
            fp.write(json.dumps(row, ensure_ascii=True) + "\n")

    def write_artifact(self, filename: str, payload: dict[str, Any]) -> Path:
        path = self.artifacts_dir / filename
        with path.open("w", encoding="utf-8") as fp:
            json.dump(payload, fp, indent=2, ensure_ascii=True)
            fp.write("\n")
        return path


@dataclass
class BleDeviceRow:
    name: str
    address: str
    rssi: int
    details: dict[str, Any]


class BleWorker:
    def __init__(self, out_queue: queue.Queue[dict[str, Any]], logger: SessionLogger) -> None:
        self.out_queue = out_queue
        self.logger = logger
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run_loop, daemon=True)
        self.thread.start()
        self.client: Any | None = None
        self.connected_address = ""
        self.notify_enabled: set[str] = set()
        self.last_scan_by_address: dict[str, Any] = {}
        self.connect_lock = asyncio.Lock()
        self.bleak_ok = False
        self.bleak_error = ""
        self._check_bleak()

    def _run_loop(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def _check_bleak(self) -> None:
        try:
            import bleak  # noqa: F401

            self.bleak_ok = True
        except Exception as exc:
            self.bleak_ok = False
            self.bleak_error = str(exc)
            self.logger.error("bleak_import_failed", str(exc))

    def publish(self, event: str, payload: dict[str, Any] | None = None) -> None:
        self.out_queue.put({"event": event, "payload": payload or {}})

    def run(self, coro: asyncio.Future[Any] | asyncio.Task[Any] | Any) -> None:
        asyncio.run_coroutine_threadsafe(coro, self.loop)

    @staticmethod
    def _norm_addr(address: str) -> str:
        text = (address or "").strip().upper()
        return "".join(ch for ch in text if ch.isalnum())

    async def _resolve_connect_target(self, normalized_address: str, name_hint: str = "", timeout: float = 5.0) -> Any | None:
        from bleak import BleakScanner

        cached = self.last_scan_by_address.get(normalized_address)
        if cached is not None:
            return cached

        found = await BleakScanner.find_device_by_address(normalized_address, timeout=timeout)
        if found is not None:
            self.last_scan_by_address[normalized_address] = found
            return found

        discovered = await BleakScanner.discover(timeout=timeout)
        norm_target = self._norm_addr(normalized_address)
        for dev in discovered:
            dev_addr = (getattr(dev, "address", "") or "").upper()
            if not dev_addr:
                continue
            if self._norm_addr(dev_addr) == norm_target:
                self.last_scan_by_address[normalized_address] = dev
                return dev

        hint = (name_hint or "").strip().lower()
        if hint and hint != "(no name)":
            for dev in discovered:
                dev_name = (getattr(dev, "name", "") or "").strip().lower()
                if dev_name and dev_name == hint:
                    return dev
        return None

    @staticmethod
    def _manufacturer_signature(metadata: dict[str, Any]) -> str:
        if not isinstance(metadata, dict):
            return ""
        mfg = metadata.get("manufacturer_data")
        if not isinstance(mfg, dict) or not mfg:
            return ""
        parts: list[str] = []
        for key in sorted(mfg.keys(), key=lambda x: str(x)):
            raw = mfg.get(key)
            if isinstance(raw, (bytes, bytearray)):
                payload = bytes(raw).hex()
            else:
                payload = str(raw)
            parts.append(f"{key}:{payload}")
        return "|".join(parts)

    @staticmethod
    def _sanitize_adv_metadata(adv: Any) -> dict[str, Any]:
        out: dict[str, Any] = {}
        local_name = getattr(adv, "local_name", "")
        if local_name:
            out["local_name"] = str(local_name)
        service_uuids = getattr(adv, "service_uuids", None)
        if isinstance(service_uuids, list) and service_uuids:
            out["service_uuids"] = [str(x) for x in service_uuids]
        tx_power = getattr(adv, "tx_power", None)
        if tx_power is not None:
            try:
                out["tx_power"] = int(tx_power)
            except Exception:
                out["tx_power"] = str(tx_power)
        connectable = getattr(adv, "connectable", None)
        if connectable is not None:
            out["connectable"] = bool(connectable)

        manufacturer_data = getattr(adv, "manufacturer_data", None)
        if isinstance(manufacturer_data, dict) and manufacturer_data:
            mfg_safe: dict[str, str] = {}
            for key, raw in manufacturer_data.items():
                key_text = str(key)
                if isinstance(raw, (bytes, bytearray)):
                    mfg_safe[key_text] = bytes(raw).hex()
                else:
                    mfg_safe[key_text] = str(raw)
            out["manufacturer_data"] = mfg_safe
        return out

    async def _resolve_connect_target_fresh(
        self,
        normalized_address: str,
        name_hint: str = "",
        metadata_hint: dict[str, Any] | None = None,
        timeout: float = 6.0,
    ) -> tuple[Any | None, str]:
        from bleak import BleakScanner

        self.publish("log", {"message": f"Fresh resolve scan for {timeout:.1f}s..."})
        target_norm = self._norm_addr(normalized_address)
        hint_name = (name_hint or "").strip().lower()
        hint_sig = self._manufacturer_signature(metadata_hint or {})

        try:
            adv_map = await BleakScanner.discover(timeout=timeout, return_adv=True)
        except TypeError:
            adv_map = None
        except Exception:
            adv_map = None

        if isinstance(adv_map, dict) and adv_map:
            fallback_by_name = None
            fallback_by_sig = None
            for _, pair in adv_map.items():
                if not isinstance(pair, tuple) or len(pair) != 2:
                    continue
                dev, adv = pair
                addr = (getattr(dev, "address", "") or "").upper()
                if self._norm_addr(addr) == target_norm:
                    return dev, "fresh-adv-address"

                if hint_name and hint_name != "(no name)":
                    dev_name = (getattr(dev, "name", "") or "").strip().lower()
                    adv_name = (getattr(adv, "local_name", "") or "").strip().lower()
                    if dev_name == hint_name or adv_name == hint_name:
                        fallback_by_name = dev

                if hint_sig:
                    mfg = getattr(adv, "manufacturer_data", None)
                    if isinstance(mfg, dict) and mfg:
                        current_sig = self._manufacturer_signature({"manufacturer_data": mfg})
                        if current_sig and current_sig == hint_sig:
                            fallback_by_sig = dev

            if fallback_by_name is not None:
                return fallback_by_name, "fresh-adv-name"
            if fallback_by_sig is not None:
                return fallback_by_sig, "fresh-adv-mfg"

        # Fallback for bleak backends without return_adv support.
        discovered = await BleakScanner.discover(timeout=timeout)
        fallback = None
        for dev in discovered:
            addr = (getattr(dev, "address", "") or "").upper()
            if self._norm_addr(addr) == target_norm:
                return dev, "fresh-discover-address"
            if fallback is None and hint_name and hint_name != "(no name)":
                dev_name = (getattr(dev, "name", "") or "").strip().lower()
                if dev_name and dev_name == hint_name:
                    fallback = dev
        if fallback is not None:
            return fallback, "fresh-discover-name"
        return None, "fresh-miss"

    async def scan(self, timeout: float) -> None:
        if not self.bleak_ok:
            self.publish(
                "error",
                {
                    "message": "Bleak is not installed. Run: python -m pip install --user bleak",
                    "detail": self.bleak_error,
                },
            )
            return
        try:
            from bleak import BleakScanner

            self.publish("log", {"message": f"Scanning BLE for {timeout:.1f}s..."})
            self.logger.log("scan_started", {"timeout": timeout})
            self.last_scan_by_address.clear()
            rows: list[dict[str, Any]] = []
            used_adv_scan = False
            try:
                adv_map = await BleakScanner.discover(timeout=timeout, return_adv=True)
            except TypeError:
                adv_map = None
            except Exception:
                adv_map = None

            if isinstance(adv_map, dict) and adv_map:
                used_adv_scan = True
                for _, pair in adv_map.items():
                    if not isinstance(pair, tuple) or len(pair) != 2:
                        continue
                    dev, adv = pair
                    addr = (getattr(dev, "address", "") or "").upper()
                    if addr:
                        self.last_scan_by_address[addr] = dev
                    dev_name = (getattr(dev, "name", "") or "").strip()
                    adv_name = (getattr(adv, "local_name", "") or "").strip()
                    name = dev_name or adv_name or "(no name)"
                    rssi_value = getattr(adv, "rssi", getattr(dev, "rssi", -999))
                    try:
                        rssi = int(rssi_value)
                    except Exception:
                        rssi = -999

                    metadata = getattr(dev, "metadata", {}) or {}
                    if not isinstance(metadata, dict):
                        metadata = {}
                    metadata = dict(metadata)
                    metadata.update(self._sanitize_adv_metadata(adv))
                    rows.append(
                        {
                            "name": name,
                            "address": addr,
                            "rssi": rssi,
                            "details": {
                                "name": dev_name,
                                "local_name": adv_name,
                                "address": addr,
                                "rssi": rssi,
                                "metadata": metadata,
                            },
                        }
                    )
            else:
                devices = await BleakScanner.discover(timeout=timeout)
                for dev in devices:
                    addr = (dev.address or "").upper()
                    if addr:
                        self.last_scan_by_address[addr] = dev
                    rows.append(
                        {
                            "name": dev.name or "(no name)",
                            "address": addr,
                            "rssi": int(getattr(dev, "rssi", -999)),
                            "details": {
                                "name": dev.name or "",
                                "address": addr,
                                "rssi": int(getattr(dev, "rssi", -999)),
                                "metadata": getattr(dev, "metadata", {}) or {},
                            },
                        }
                    )
            rows.sort(key=lambda d: d.get("rssi", -999), reverse=True)
            scan_record = {
                "time": iso_time(),
                "count": len(rows),
                "used_adv_scan": used_adv_scan,
                "devices": rows,
            }
            stamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
            self.logger.write_artifact("ble_devices_latest.json", scan_record)
            self.logger.write_artifact(f"ble_devices_{stamp}.json", scan_record)
            self.publish("scan_results", {"devices": rows})
            self.logger.log(
                "scan_finished",
                {"count": len(rows), "artifact": "artifacts/ble_devices_latest.json", "used_adv_scan": used_adv_scan},
            )
        except Exception as exc:
            self.publish("error", {"message": f"Scan failed: {exc}"})
            self.logger.error("scan_failed", str(exc), {"traceback": traceback.format_exc(limit=20)})

    async def connect(
        self,
        address: str,
        name_hint: str = "",
        metadata_hint: dict[str, Any] | None = None,
        timeout: float = 12.0,
    ) -> None:
        if not self.bleak_ok:
            self.publish(
                "error",
                {
                    "message": "Bleak is not installed. Run: python -m pip install --user bleak",
                    "detail": self.bleak_error,
                },
            )
            return
        if not address:
            self.publish("error", {"message": "No address selected."})
            return
        if self.connect_lock.locked():
            self.publish("error", {"message": "Connect already running. Wait for current attempt to finish."})
            return
        async with self.connect_lock:
            try:
                await self.disconnect(silent=True)
                from bleak import BleakClient

                normalized_address = address.strip().upper()
                last_error = ""
                connected = False
                attempts = 4
                use_cache = True
                for attempt in range(1, attempts + 1):
                    self.publish(
                        "log",
                        {
                            "message": (
                                f"Connect attempt {attempt}/{attempts} for {normalized_address}"
                                + (f" (name hint: {name_hint})" if name_hint else "")
                            )
                        },
                    )
                    resolution_path = "cache"
                    target = None
                    if use_cache:
                        target = await self._resolve_connect_target(
                            normalized_address,
                            name_hint=name_hint,
                            timeout=min(3.0, timeout),
                        )
                        resolution_path = "cache-resolve"
                    if target is None:
                        target, resolution_path = await self._resolve_connect_target_fresh(
                            normalized_address,
                            name_hint=name_hint,
                            metadata_hint=metadata_hint,
                            timeout=min(8.0, timeout),
                        )
                    if target is None:
                        last_error = "device not discoverable during connect attempt"
                        self.publish("log", {"message": f"Resolve failed ({resolution_path}); retrying..."})
                        use_cache = False
                        await asyncio.sleep(0.4)
                        continue

                    target_address = (getattr(target, "address", "") or "").strip().upper()
                    connect_variants: list[tuple[str, Any]] = []
                    connect_variants.append(("device-object", target))
                    if normalized_address:
                        connect_variants.append(("address-string", normalized_address))
                    if target_address and target_address != normalized_address:
                        connect_variants.append(("resolved-address", target_address))

                    for mode, connect_target in connect_variants:
                        try:
                            self.publish(
                                "log",
                                {"message": f"Resolved via {resolution_path}; connect mode={mode}, timeout={timeout:.1f}s"},
                            )
                            client = BleakClient(connect_target, timeout=timeout)
                            ok = await client.connect()
                            if not ok:
                                raise RuntimeError("Connect returned false")
                            self.client = client
                            self.connected_address = target_address or normalized_address
                            self.notify_enabled.clear()
                            self.publish("connected", {"address": self.connected_address})
                            self.logger.log(
                                "connect_ok",
                                {
                                    "address": self.connected_address,
                                    "attempt": attempt,
                                    "name_hint": name_hint,
                                    "resolution_path": resolution_path,
                                    "mode": mode,
                                },
                            )
                            connected = True
                            await self.discover_services()
                            break
                        except Exception as inner_exc:
                            last_error = str(inner_exc)
                            self.publish("log", {"message": f"Connect mode={mode} failed: {last_error}"})
                            if "not found" in last_error.lower():
                                use_cache = False
                                self.last_scan_by_address.pop(normalized_address, None)
                            try:
                                await asyncio.sleep(0.25)
                            except Exception:
                                pass
                    if connected:
                        break

                if not connected:
                    raise RuntimeError(last_error or "connect failed after retries")
            except Exception as exc:
                detail = str(exc)
                if "was not found" in detail.lower():
                    detail = (
                        f"{detail}. Device likely stopped advertising or uses rotating BLE address. "
                        "Keep it in pairing mode and click Scan then Connect immediately."
                    )
                self.publish("error", {"message": f"Connect failed: {detail}"})
                self.logger.error(
                    "connect_failed",
                    detail,
                    {
                        "address": address,
                        "name_hint": name_hint,
                        "metadata_hint_keys": sorted((metadata_hint or {}).keys()),
                        "traceback": traceback.format_exc(limit=20),
                    },
                )

    async def disconnect(self, silent: bool = False) -> None:
        client = self.client
        self.client = None
        self.notify_enabled.clear()
        if client is None:
            if not silent:
                self.publish("log", {"message": "No active BLE connection."})
            return
        try:
            await client.disconnect()
            self.logger.log("disconnect_ok", {"address": self.connected_address})
            self.connected_address = ""
            if not silent:
                self.publish("disconnected", {})
        except Exception as exc:
            self.logger.error("disconnect_failed", str(exc), {"traceback": traceback.format_exc(limit=20)})
            if not silent:
                self.publish("error", {"message": f"Disconnect failed: {exc}"})

    async def discover_services(self) -> None:
        client = self.client
        if client is None or not client.is_connected:
            self.publish("error", {"message": "Not connected."})
            return
        try:
            services = client.services
            if services is None:
                services = await client.get_services()
            out: list[dict[str, Any]] = []
            for svc in services:
                for char in svc.characteristics:
                    props = list(char.properties or [])
                    out.append(
                        {
                            "service_uuid": str(svc.uuid),
                            "char_uuid": str(char.uuid),
                            "description": str(char.description or ""),
                            "handle": int(getattr(char, "handle", 0)),
                            "properties": props,
                        }
                    )
            record = {
                "time": iso_time(),
                "address": self.connected_address,
                "count": len(out),
                "characteristics": out,
            }
            safe_addr = self.connected_address.replace(":", "_").replace("/", "_")
            stamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
            self.logger.write_artifact("ble_characteristics_latest.json", record)
            if safe_addr:
                self.logger.write_artifact(f"ble_characteristics_{safe_addr}_{stamp}.json", record)
            self.publish("services", {"rows": out})
            self.logger.log(
                "services_loaded",
                {
                    "count": len(out),
                    "address": self.connected_address,
                    "artifact": "artifacts/ble_characteristics_latest.json",
                },
            )
        except Exception as exc:
            self.publish("error", {"message": f"Service discovery failed: {exc}"})
            self.logger.error("services_failed", str(exc), {"traceback": traceback.format_exc(limit=20)})

    async def read_char(self, char_uuid: str) -> None:
        client = self.client
        if client is None or not client.is_connected:
            self.publish("error", {"message": "Not connected."})
            return
        try:
            data = await client.read_gatt_char(char_uuid)
            msg = f"READ {char_uuid}: {hex_preview(data)}"
            self.publish("read_result", {"char_uuid": char_uuid, "hex": data.hex(), "ascii": data.decode(errors='replace')})
            self.publish("log", {"message": msg})
            self.logger.log(
                "read_ok",
                {
                    "address": self.connected_address,
                    "char_uuid": char_uuid,
                    "bytes": len(data),
                    "hex": data.hex(),
                    "ascii": data.decode(errors="replace"),
                    "preview": hex_preview(data, limit=24),
                },
            )
        except Exception as exc:
            self.publish("error", {"message": f"Read failed ({char_uuid}): {exc}"})
            self.logger.error("read_failed", str(exc), {"char_uuid": char_uuid, "traceback": traceback.format_exc(limit=20)})

    async def write_char(self, char_uuid: str, payload: bytes, response: bool) -> None:
        client = self.client
        if client is None or not client.is_connected:
            self.publish("error", {"message": "Not connected."})
            return
        if not payload:
            self.publish("error", {"message": "Write payload is empty."})
            return
        try:
            await client.write_gatt_char(char_uuid, payload, response=response)
            self.publish("log", {"message": f"WRITE {char_uuid}: {hex_preview(payload)} (response={response})"})
            self.logger.log(
                "write_ok",
                {
                    "address": self.connected_address,
                    "char_uuid": char_uuid,
                    "bytes": len(payload),
                    "response": response,
                    "hex": payload.hex(),
                    "ascii": payload.decode(errors="replace"),
                    "preview": hex_preview(payload, limit=24),
                },
            )
        except Exception as exc:
            self.publish("error", {"message": f"Write failed ({char_uuid}): {exc}"})
            self.logger.error("write_failed", str(exc), {"char_uuid": char_uuid, "traceback": traceback.format_exc(limit=20)})

    async def toggle_notify(self, char_uuid: str, enable: bool) -> None:
        client = self.client
        if client is None or not client.is_connected:
            self.publish("error", {"message": "Not connected."})
            return
        try:
            if enable:
                async def _start() -> None:
                    await client.start_notify(char_uuid, self._notification_handler(char_uuid))

                await _start()
                self.notify_enabled.add(char_uuid)
                self.publish("log", {"message": f"NOTIFY ON {char_uuid}"})
                self.logger.log("notify_on", {"char_uuid": char_uuid})
            else:
                await client.stop_notify(char_uuid)
                self.notify_enabled.discard(char_uuid)
                self.publish("log", {"message": f"NOTIFY OFF {char_uuid}"})
                self.logger.log("notify_off", {"char_uuid": char_uuid})
        except Exception as exc:
            self.publish("error", {"message": f"Notify toggle failed ({char_uuid}): {exc}"})
            self.logger.error("notify_toggle_failed", str(exc), {"char_uuid": char_uuid, "traceback": traceback.format_exc(limit=20)})

    def _notification_handler(self, char_uuid: str):
        def _cb(_: Any, data: bytes) -> None:
            self.publish("notify", {"char_uuid": char_uuid, "hex": data.hex(), "ascii": data.decode(errors="replace")})
            self.logger.log(
                "notify_rx",
                {
                    "address": self.connected_address,
                    "char_uuid": char_uuid,
                    "bytes": len(data),
                    "hex": data.hex(),
                    "ascii": data.decode(errors="replace"),
                    "preview": hex_preview(data, limit=24),
                },
            )

        return _cb

    async def shutdown(self) -> None:
        await self.disconnect(silent=True)


class BleScannerApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("RGB Light Bluetooth Scanner")
        self.root.geometry("1240x780")
        self.root.minsize(1000, 640)

        app_root = Path(__file__).resolve().parent
        self.logger = SessionLogger(app_root)
        self.event_queue: queue.Queue[dict[str, Any]] = queue.Queue()
        self.worker = BleWorker(self.event_queue, self.logger)

        self.devices: list[BleDeviceRow] = []
        self.service_rows: list[dict[str, Any]] = []
        self.service_by_uuid: dict[str, dict[str, Any]] = {}
        self.selected_char_uuid = ""
        self.notify_on = tk.BooleanVar(value=False)
        self.write_mode = tk.StringVar(value="hex")
        self.write_with_response = tk.BooleanVar(value=False)
        self.scan_seconds = tk.StringVar(value="8")
        self.status_var = tk.StringVar(value="Ready")
        self.connected_var = tk.StringVar(value="Disconnected")

        self._build_ui()
        self._queue_pump()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        if not self.worker.bleak_ok:
            self._append_log(
                "Bleak not installed. Install with: python -m pip install --user bleak\n"
                f"Detail: {self.worker.bleak_error}"
            )
        self._append_log(f"Session logs: {self.logger.session_dir}")
        self._append_log("Artifacts: devices/characteristics snapshots saved in session artifacts folder.")

    def _build_ui(self) -> None:
        top = ttk.Frame(self.root, padding=8)
        top.pack(fill=tk.X)

        ttk.Label(top, text="Scan Seconds:").pack(side=tk.LEFT)
        scan_entry = ttk.Entry(top, textvariable=self.scan_seconds, width=6)
        scan_entry.pack(side=tk.LEFT, padx=(4, 10))

        ttk.Button(top, text="Scan BLE", command=self.on_scan).pack(side=tk.LEFT, padx=4)
        ttk.Button(top, text="Connect", command=self.on_connect).pack(side=tk.LEFT, padx=4)
        ttk.Button(top, text="Disconnect", command=self.on_disconnect).pack(side=tk.LEFT, padx=4)
        ttk.Button(top, text="Refresh Services", command=self.on_refresh_services).pack(side=tk.LEFT, padx=4)
        ttk.Button(top, text="Clear Log", command=self.clear_log).pack(side=tk.LEFT, padx=4)

        ttk.Label(top, textvariable=self.connected_var).pack(side=tk.RIGHT, padx=4)
        ttk.Label(top, textvariable=self.status_var).pack(side=tk.RIGHT, padx=12)

        main = ttk.Panedwindow(self.root, orient=tk.HORIZONTAL)
        main.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))

        left = ttk.Labelframe(main, text="Discovered BLE Devices", padding=8)
        center = ttk.Labelframe(main, text="Services / Characteristics", padding=8)
        right = ttk.Labelframe(main, text="Characteristic Test", padding=8)
        main.add(left, weight=3)
        main.add(center, weight=4)
        main.add(right, weight=4)

        self.device_tree = ttk.Treeview(left, columns=("name", "address", "rssi"), show="headings", height=18)
        for key, title, width in (
            ("name", "Name", 200),
            ("address", "Address", 180),
            ("rssi", "RSSI", 60),
        ):
            self.device_tree.heading(key, text=title)
            self.device_tree.column(key, width=width, anchor=tk.W)
        self.device_tree.pack(fill=tk.BOTH, expand=True)
        self.device_tree.bind("<<TreeviewSelect>>", self.on_select_device)

        dev_scroll = ttk.Scrollbar(left, orient=tk.VERTICAL, command=self.device_tree.yview)
        self.device_tree.configure(yscroll=dev_scroll.set)
        dev_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        self.char_tree = ttk.Treeview(
            center,
            columns=("char_uuid", "service_uuid", "props", "desc"),
            show="headings",
            height=18,
        )
        for key, title, width in (
            ("char_uuid", "Characteristic UUID", 260),
            ("service_uuid", "Service UUID", 220),
            ("props", "Properties", 180),
            ("desc", "Description", 180),
        ):
            self.char_tree.heading(key, text=title)
            self.char_tree.column(key, width=width, anchor=tk.W)
        self.char_tree.pack(fill=tk.BOTH, expand=True)
        self.char_tree.bind("<<TreeviewSelect>>", self.on_select_char)

        char_scroll = ttk.Scrollbar(center, orient=tk.VERTICAL, command=self.char_tree.yview)
        self.char_tree.configure(yscroll=char_scroll.set)
        char_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        row = ttk.Frame(right)
        row.pack(fill=tk.X, pady=(0, 8))
        ttk.Label(row, text="Selected Char UUID:").pack(side=tk.LEFT)
        self.selected_char_label = ttk.Label(row, text="-")
        self.selected_char_label.pack(side=tk.LEFT, padx=6)

        self.capabilities_label = ttk.Label(right, text="Capabilities: -")
        self.capabilities_label.pack(fill=tk.X, pady=(0, 10))

        cmd = ttk.Frame(right)
        cmd.pack(fill=tk.X, pady=(0, 8))
        ttk.Button(cmd, text="Read", command=self.on_read).pack(side=tk.LEFT, padx=4)
        ttk.Checkbutton(cmd, text="Notify", variable=self.notify_on, command=self.on_toggle_notify).pack(side=tk.LEFT, padx=4)

        mode = ttk.Frame(right)
        mode.pack(fill=tk.X, pady=(0, 8))
        ttk.Label(mode, text="Write Mode:").pack(side=tk.LEFT)
        ttk.Radiobutton(mode, text="HEX", value="hex", variable=self.write_mode).pack(side=tk.LEFT, padx=4)
        ttk.Radiobutton(mode, text="ASCII", value="ascii", variable=self.write_mode).pack(side=tk.LEFT, padx=4)
        ttk.Checkbutton(mode, text="Write with response", variable=self.write_with_response).pack(side=tk.LEFT, padx=10)

        self.write_entry = ttk.Entry(right)
        self.write_entry.pack(fill=tk.X, pady=(0, 8))
        self.write_entry.insert(0, "7e 00 05 03 00 00 00 ef")

        write_btns = ttk.Frame(right)
        write_btns.pack(fill=tk.X, pady=(0, 8))
        ttk.Button(write_btns, text="Send Write", command=self.on_write).pack(side=tk.LEFT, padx=4)
        ttk.Button(write_btns, text="Try ON (sample)", command=self.on_sample_on).pack(side=tk.LEFT, padx=4)
        ttk.Button(write_btns, text="Try OFF (sample)", command=self.on_sample_off).pack(side=tk.LEFT, padx=4)
        ttk.Button(write_btns, text="Try Brightness 50% (sample)", command=self.on_sample_brightness).pack(side=tk.LEFT, padx=4)

        ttk.Label(
            right,
            text=(
                "Sample commands are common Tuya-like BLE payloads and may not match your controller.\n"
                "Use only for testing; check notifications/readback for supported behavior."
            ),
        ).pack(fill=tk.X, pady=(0, 8))

        log_box = ttk.Labelframe(self.root, text="Live Log", padding=8)
        log_box.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))
        self.log_text = tk.Text(log_box, height=14, wrap=tk.WORD)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        log_scroll = ttk.Scrollbar(log_box, orient=tk.VERTICAL, command=self.log_text.yview)
        self.log_text.configure(yscroll=log_scroll.set)
        log_scroll.pack(side=tk.RIGHT, fill=tk.Y)

    def _append_log(self, line: str) -> None:
        ts = datetime.now().strftime("%H:%M:%S")
        self.log_text.insert(tk.END, f"[{ts}] {line}\n")
        self.log_text.see(tk.END)
        self.logger.log("ui_log", {"message": line})

    def clear_log(self) -> None:
        self.log_text.delete("1.0", tk.END)

    def _queue_pump(self) -> None:
        try:
            while True:
                msg = self.event_queue.get_nowait()
                self._handle_event(msg)
        except queue.Empty:
            pass
        self.root.after(120, self._queue_pump)

    def _handle_event(self, msg: dict[str, Any]) -> None:
        event = msg.get("event", "")
        payload = msg.get("payload", {}) or {}
        if event == "log":
            self._append_log(str(payload.get("message", "")))
            return
        if event == "error":
            message = str(payload.get("message", "Unknown error"))
            detail = str(payload.get("detail", ""))
            self._append_log(f"ERROR: {message}{f' | {detail}' if detail else ''}")
            self.status_var.set("Error")
            return
        if event == "scan_results":
            self.populate_devices(payload.get("devices", []))
            self.status_var.set("Scan complete")
            self._append_log(f"Scan done: {len(self.devices)} BLE device(s) found.")
            return
        if event == "connected":
            addr = str(payload.get("address", ""))
            self.connected_var.set(f"Connected: {addr}")
            self.status_var.set("Connected")
            self._append_log(f"Connected to {addr}")
            return
        if event == "disconnected":
            self.connected_var.set("Disconnected")
            self.status_var.set("Disconnected")
            self._append_log("Disconnected.")
            self.service_rows.clear()
            self.service_by_uuid.clear()
            for item in self.char_tree.get_children():
                self.char_tree.delete(item)
            return
        if event == "services":
            rows = payload.get("rows", [])
            self.populate_services(rows if isinstance(rows, list) else [])
            self.status_var.set("Services loaded")
            self._append_log(f"Loaded {len(self.service_rows)} characteristic(s).")
            return
        if event == "read_result":
            char_uuid = str(payload.get("char_uuid", ""))
            hx = str(payload.get("hex", ""))
            asc = str(payload.get("ascii", ""))
            self._append_log(f"READ [{char_uuid}] hex={hx} ascii={asc}")
            return
        if event == "notify":
            char_uuid = str(payload.get("char_uuid", ""))
            hx = str(payload.get("hex", ""))
            asc = str(payload.get("ascii", ""))
            self._append_log(f"NOTIFY [{char_uuid}] hex={hx} ascii={asc}")
            return

    def populate_devices(self, rows: list[dict[str, Any]]) -> None:
        self.devices.clear()
        for item in self.device_tree.get_children():
            self.device_tree.delete(item)
        for d in rows:
            row = BleDeviceRow(
                name=str(d.get("name", "(no name)")),
                address=str(d.get("address", "")),
                rssi=int(d.get("rssi", -999)),
                details=d.get("details", {}) if isinstance(d.get("details"), dict) else {},
            )
            self.devices.append(row)
            self.device_tree.insert("", tk.END, values=(row.name, row.address, row.rssi))

    def populate_services(self, rows: list[dict[str, Any]]) -> None:
        self.service_rows = rows
        self.service_by_uuid = {}
        for item in self.char_tree.get_children():
            self.char_tree.delete(item)
        for row in rows:
            char_uuid = str(row.get("char_uuid", ""))
            props = ", ".join([str(p) for p in row.get("properties", [])])
            self.service_by_uuid[char_uuid] = row
            self.char_tree.insert(
                "",
                tk.END,
                values=(
                    char_uuid,
                    str(row.get("service_uuid", "")),
                    props,
                    str(row.get("description", "")),
                ),
            )

    def _selected_device(self) -> BleDeviceRow | None:
        selected = self.device_tree.selection()
        if not selected:
            return None
        idx = self.device_tree.index(selected[0])
        if idx < 0 or idx >= len(self.devices):
            return None
        return self.devices[idx]

    def _selected_char(self) -> str:
        selected = self.char_tree.selection()
        if not selected:
            return ""
        values = self.char_tree.item(selected[0], "values")
        if not values:
            return ""
        return str(values[0])

    def on_select_device(self, _: Any) -> None:
        dev = self._selected_device()
        if dev is None:
            return
        md = dev.details.get("metadata", {}) if isinstance(dev.details.get("metadata"), dict) else {}
        self._append_log(f"Selected device: {dev.name} | {dev.address} | RSSI={dev.rssi} | metadata_keys={list(md.keys())}")

    def on_select_char(self, _: Any) -> None:
        char_uuid = self._selected_char()
        self.selected_char_uuid = char_uuid
        self.selected_char_label.config(text=char_uuid or "-")
        row = self.service_by_uuid.get(char_uuid, {})
        props = row.get("properties", [])
        if isinstance(props, list):
            capabilities = ", ".join([str(p) for p in props]) if props else "-"
        else:
            capabilities = str(props)
        self.capabilities_label.config(text=f"Capabilities: {capabilities}")
        self.notify_on.set(char_uuid in self.worker.notify_enabled)

    def _parse_scan_seconds(self) -> float:
        try:
            value = float(self.scan_seconds.get().strip())
            if value <= 0:
                raise ValueError("must be > 0")
            return min(value, 40.0)
        except Exception:
            return 8.0

    def on_scan(self) -> None:
        timeout = self._parse_scan_seconds()
        self.status_var.set("Scanning...")
        self.worker.run(self.worker.scan(timeout))

    def on_connect(self) -> None:
        dev = self._selected_device()
        if dev is None:
            messagebox.showwarning("Select Device", "Select a BLE device first.")
            return
        self.status_var.set("Connecting...")
        self.worker.run(self.worker.connect(dev.address, name_hint=dev.name, metadata_hint=dev.details.get("metadata", {})))

    def on_disconnect(self) -> None:
        self.status_var.set("Disconnecting...")
        self.worker.run(self.worker.disconnect())

    def on_refresh_services(self) -> None:
        self.status_var.set("Refreshing services...")
        self.worker.run(self.worker.discover_services())

    def on_read(self) -> None:
        char_uuid = self._selected_char()
        if not char_uuid:
            messagebox.showwarning("Select Characteristic", "Select a characteristic first.")
            return
        self.worker.run(self.worker.read_char(char_uuid))

    def _parse_write_payload(self) -> bytes | None:
        raw = self.write_entry.get().strip()
        if not raw:
            messagebox.showwarning("Write Payload", "Enter payload first.")
            return None
        mode = self.write_mode.get()
        try:
            if mode == "ascii":
                return raw.encode("utf-8")
            cleaned = raw.replace("0x", "").replace(",", " ")
            cleaned = " ".join(cleaned.split())
            if " " in cleaned:
                return bytes(int(part, 16) for part in cleaned.split(" "))
            return bytes.fromhex(cleaned)
        except Exception as exc:
            messagebox.showerror("Invalid Payload", f"Could not parse payload: {exc}")
            return None

    def on_write(self) -> None:
        char_uuid = self._selected_char()
        if not char_uuid:
            messagebox.showwarning("Select Characteristic", "Select a characteristic first.")
            return
        payload = self._parse_write_payload()
        if payload is None:
            return
        response = bool(self.write_with_response.get())
        self.worker.run(self.worker.write_char(char_uuid, payload, response))

    def on_toggle_notify(self) -> None:
        char_uuid = self._selected_char()
        if not char_uuid:
            self.notify_on.set(False)
            messagebox.showwarning("Select Characteristic", "Select a characteristic first.")
            return
        enable = bool(self.notify_on.get())
        self.worker.run(self.worker.toggle_notify(char_uuid, enable))

    def on_sample_on(self) -> None:
        # Common Tuya-like packet pattern used by some RGB BLE controllers.
        self.write_mode.set("hex")
        self.write_entry.delete(0, tk.END)
        self.write_entry.insert(0, "7e 00 05 01 01 00 00 ef")

    def on_sample_off(self) -> None:
        self.write_mode.set("hex")
        self.write_entry.delete(0, tk.END)
        self.write_entry.insert(0, "7e 00 05 01 00 00 00 ef")

    def on_sample_brightness(self) -> None:
        self.write_mode.set("hex")
        self.write_entry.delete(0, tk.END)
        self.write_entry.insert(0, "7e 00 08 02 00 32 00 00 00 ef")

    def _on_close(self) -> None:
        try:
            self.worker.run(self.worker.shutdown())
        except Exception:
            pass
        self.logger.log("session_closed", {})
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    BleScannerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
