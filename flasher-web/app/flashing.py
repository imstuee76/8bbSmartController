from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

import serial
from serial.tools import list_ports

from .storage import DATA_DIR, append_event, get_connection, utc_now

_lock = threading.Lock()
MAX_FLASH_OUTPUT = 250_000


def _capture_runtime_serial(port: str, baud: int, seconds: float = 5.0) -> tuple[list[str], str]:
    lines: list[str] = []
    try:
        with serial.Serial(port, baud, timeout=0.2) as ser:
            started = time.monotonic()
            while time.monotonic() - started < seconds:
                raw = ser.readline()
                if not raw:
                    continue
                text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                if text:
                    lines.append(text)
    except Exception as exc:
        return lines, str(exc)
    return lines, ""


def _capture_runtime_serial_with_retries(
    port: str,
    baud: int,
    seconds: float = 5.0,
    retries: int = 8,
    retry_delay: float = 0.35,
) -> tuple[list[str], str, list[str]]:
    last_lines: list[str] = []
    last_error = ""
    retry_errors: list[str] = []
    attempts = max(1, retries)
    for idx in range(attempts):
        lines, err = _capture_runtime_serial(port, baud, seconds=seconds)
        if not err:
            return lines, "", retry_errors
        last_lines = lines
        last_error = err
        retry_errors.append(err)
        low = err.lower()
        if "access is denied" not in low and "permissionerror" not in low:
            return lines, err, retry_errors
        if idx < attempts - 1:
            time.sleep(retry_delay)
    return last_lines, last_error, retry_errors


def _pulse_reset_on_uart(port: str, baud: int) -> tuple[bool, str]:
    # Best-effort reset pulse via UART control lines so probe can capture boot/runtime logs.
    try:
        with serial.Serial(port, baud, timeout=0.2) as ser:
            try:
                ser.dtr = False
                ser.rts = False
                time.sleep(0.05)
                ser.rts = True
                time.sleep(0.12)
                ser.rts = False
                time.sleep(0.08)
            except Exception:
                # Some adapters may not expose both lines; still try DTR pulse.
                ser.dtr = True
                time.sleep(0.08)
                ser.dtr = False
                time.sleep(0.08)
            try:
                ser.reset_input_buffer()
            except Exception:
                pass
        return True, ""
    except Exception as exc:
        return False, str(exc)


def _extract_runtime_network_summary(lines: list[str]) -> dict:
    summary: dict = {"mode": "unknown"}
    net_ok_re = re.compile(
        r"NET_OK\s+name=(?P<name>\S+)\s+host=(?P<host>\S+)\s+ip=(?P<ip>[0-9.]+)\s+gw=(?P<gw>[0-9.]+)\s+mask=(?P<mask>[0-9.]+)",
        flags=re.IGNORECASE,
    )
    net_ap_re = re.compile(
        r"NET_AP\s+name=(?P<name>\S+)\s+ap_ssid=(?P<ssid>\S+)\s+ip=(?P<ip>[0-9.]+)\s+gw=(?P<gw>[0-9.]+)\s+mask=(?P<mask>[0-9.]+)",
        flags=re.IGNORECASE,
    )
    reason_re = re.compile(r"reason\s*=\s*(\d+)")

    for line in lines:
        m_ok = net_ok_re.search(line)
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
        m_ap = net_ap_re.search(line)
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
        if "Starting fallback AP ssid=" in line:
            summary["ap_starting"] = True
            summary["ap_start_line"] = line
        r = reason_re.search(line)
        if r:
            summary["last_wifi_reason"] = int(r.group(1))
            summary["last_wifi_reason_line"] = line

    return summary


def _find_esptool_cmd() -> tuple[list[str] | None, str]:
    direct = shutil.which("esptool.py") or shutil.which("esptool")
    if direct:
        return [direct], f"direct:{direct}"

    candidates: list[str] = []
    env_py = os.environ.get("ESP_IDF_PYTHON", "").strip()
    if env_py:
        candidates.append(env_py)
    candidates.extend(sorted(glob.glob("C:/Espressif/python_env/*/Scripts/python.exe")))
    candidates.extend(sorted(glob.glob("C:/Espressif/tools/idf-python/*/python.exe")))
    candidates.append(sys.executable)

    tried: list[str] = []
    for py in candidates:
        if not py or not Path(py).exists():
            continue
        try:
            probe = subprocess.run(
                [py, "-m", "esptool", "version"],
                capture_output=True,
                text=True,
                check=False,
                timeout=6,
            )
            tried.append(f"{py} -> rc={probe.returncode}")
            if probe.returncode == 0:
                return [py, "-m", "esptool"], f"python-module:{py}"
        except Exception as exc:
            tried.append(f"{py} -> error:{exc}")

    return None, " | ".join(tried[-6:]) if tried else "no candidates"


def start_flash_job(device_id: str | None, port: str, baud: int, firmware_filename: str) -> dict:
    firmware_path = (DATA_DIR / "firmware" / firmware_filename).resolve()
    if not firmware_path.exists():
        raise FileNotFoundError(f"Firmware file not found: {firmware_filename}")
    if firmware_path.is_dir():
        raise ValueError(f"Firmware path points to a directory: {firmware_filename}")
    if firmware_path.suffix.lower() != ".bin":
        raise ValueError(f"Firmware must be a .bin file: {firmware_filename}")

    job_id = str(uuid.uuid4())
    now = utc_now()

    conn = get_connection()
    conn.execute(
        """
        INSERT INTO flash_jobs(id, device_id, port, baud, firmware_path, status, output, created_at)
        VALUES (?, ?, ?, ?, ?, 'queued', '', ?)
        """,
        (job_id, device_id, port, baud, str(firmware_path), now),
    )
    conn.commit()
    conn.close()

    thread = threading.Thread(target=_run_job, args=(job_id,), daemon=True)
    thread.start()

    append_event("flash_job_created", {"job_id": job_id, "port": port, "firmware": firmware_filename})
    return {"job_id": job_id, "status": "queued"}


def _run_job(job_id: str) -> None:
    with _lock:
        conn = get_connection()
        row = conn.execute("SELECT * FROM flash_jobs WHERE id = ?", (job_id,)).fetchone()
        if not row:
            conn.close()
            return

        conn.execute("UPDATE flash_jobs SET status='running', started_at=? WHERE id=?", (utc_now(), job_id))
        conn.commit()

        tool_cmd, tool_source = _find_esptool_cmd()
        if not tool_cmd:
            output = "esptool not found (tried PATH and ESP-IDF Python)."
            conn.execute(
                "UPDATE flash_jobs SET status='failed', output=?, finished_at=? WHERE id=?",
                (f"{output}\n{tool_source}", utc_now(), job_id),
            )
            conn.commit()
            conn.close()
            append_event("flash_job_failed", {"job_id": job_id, "reason": output, "details": tool_source})
            return

        cmd = [
            *tool_cmd,
            "--chip",
            "esp32",
            "--port",
            row["port"],
            "--baud",
            str(row["baud"]),
            "write_flash",
            "0x0",
            row["firmware_path"],
        ]

        lines: list[str] = [f"$ {' '.join(cmd)}", f"[flash] esptool source: {tool_source}", "[flash] writing firmware to serial port..."]
        status = "failed"
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            last_flush = time.monotonic()
            if proc.stdout:
                for raw in proc.stdout:
                    line = (raw or "").rstrip("\r\n")
                    if line:
                        lines.append(line)
                    now = time.monotonic()
                    if now - last_flush > 0.5:
                        conn.execute(
                            "UPDATE flash_jobs SET output=? WHERE id=?",
                            ("\n".join(lines)[-MAX_FLASH_OUTPUT:], job_id),
                        )
                        conn.commit()
                        last_flush = now

            code = proc.wait()
            status = "success" if code == 0 else "failed"
            lines.append(f"[flash] process exit code: {code}")
            if status == "success":
                lines.append("[flash] completed successfully")
            else:
                lines.append("[flash] failed")
        except Exception as exc:
            lines.append(f"[flash] exception: {exc}")
            status = "failed"

        output = "\n".join(lines)[-MAX_FLASH_OUTPUT:]

        conn.execute(
            "UPDATE flash_jobs SET status=?, output=?, finished_at=? WHERE id=?",
            (status, output.strip(), utc_now(), job_id),
        )
        conn.commit()
        conn.close()
        append_event("flash_job_finished", {"job_id": job_id, "status": status})


def get_flash_job(job_id: str) -> dict | None:
    conn = get_connection()
    row = conn.execute("SELECT * FROM flash_jobs WHERE id=?", (job_id,)).fetchone()
    conn.close()
    if not row:
        return None
    return dict(row)


def list_ports_for_flash() -> list[dict]:
    items = []
    for port in list_ports.comports():
        items.append(
            {
                "device": port.device,
                "description": port.description,
                "hwid": port.hwid,
                "manufacturer": port.manufacturer,
            }
        )
    return items


def probe_serial_port(port: str, baud: int = 115200) -> dict:
    device = (port or "").strip()
    if not device:
        raise ValueError("port is required")
    if baud < 1200 or baud > 4_000_000:
        raise ValueError("invalid baud")

    runtime_lines, runtime_error, runtime_retry_errors = _capture_runtime_serial_with_retries(
        device,
        baud,
        seconds=10.0,
        retries=10,
        retry_delay=0.35,
    )
    runtime_summary = _extract_runtime_network_summary(runtime_lines)
    runtime_tail = "\n".join(runtime_lines[-120:])
    reset_attempted = False
    reset_ok = False
    reset_error = ""

    if not runtime_error and not runtime_lines:
        # No serial lines captured; try pulsing reset once and capture again.
        reset_attempted = True
        reset_ok, reset_error = _pulse_reset_on_uart(device, baud)
        if reset_ok:
            runtime_lines, runtime_error, reset_retry_errors = _capture_runtime_serial_with_retries(
                device,
                baud,
                seconds=8.0,
                retries=8,
                retry_delay=0.30,
            )
            runtime_retry_errors.extend(reset_retry_errors)
            runtime_summary = _extract_runtime_network_summary(runtime_lines)
            runtime_tail = "\n".join(runtime_lines[-120:])

    if runtime_error:
        low = runtime_error.lower()
        hint = ""
        if "access is denied" in low or "permissionerror" in low:
            hint = "COM port is busy. Close miniterm/Arduino/other serial apps, then retry."
        return {
            "ok": False,
            "port": device,
            "baud": baud,
            "error": runtime_error,
            "hint": hint,
            "probe_mode": "runtime_serial",
            "runtime_capture_ok": False,
            "runtime_capture_error": runtime_error,
            "runtime_summary": runtime_summary,
            "runtime_log_tail": runtime_tail,
            "runtime_retry_errors": runtime_retry_errors[-12:],
            "reset_attempted": reset_attempted,
            "reset_ok": reset_ok,
            "reset_error": reset_error,
        }

    # Runtime capture succeeded; if we got useful lines, return these directly.
    if runtime_lines:
        return {
            "ok": True,
            "port": device,
            "baud": baud,
            "probe_mode": "runtime_serial",
            "runtime_capture_ok": True,
            "runtime_capture_error": "",
            "runtime_summary": runtime_summary,
            "runtime_log_tail": runtime_tail,
            "runtime_retry_errors": runtime_retry_errors[-12:],
            "reset_attempted": reset_attempted,
            "reset_ok": reset_ok,
            "reset_error": reset_error,
        }

    tool_cmd, tool_source = _find_esptool_cmd()
    if not tool_cmd:
        return {
            "ok": False,
            "port": device,
            "baud": baud,
            "error": "No runtime serial data captured and esptool not found.",
            "details": tool_source,
            "probe_mode": "runtime_then_bootloader",
            "runtime_capture_ok": True,
            "runtime_capture_error": "",
            "runtime_summary": runtime_summary,
            "runtime_log_tail": runtime_tail,
            "runtime_retry_errors": runtime_retry_errors[-12:],
            "reset_attempted": reset_attempted,
            "reset_ok": reset_ok,
            "reset_error": reset_error,
        }

    cmd = [*tool_cmd, "--port", device, "--baud", str(baud), "chip_id"]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=20,
        )
    except Exception as exc:
        return {
            "ok": False,
            "port": device,
            "baud": baud,
            "error": str(exc),
            "tool_source": tool_source,
            "probe_mode": "runtime_then_bootloader",
            "runtime_capture_ok": True,
            "runtime_capture_error": "",
            "runtime_summary": runtime_summary,
            "runtime_log_tail": runtime_tail,
            "runtime_retry_errors": runtime_retry_errors[-12:],
            "reset_attempted": reset_attempted,
            "reset_ok": reset_ok,
            "reset_error": reset_error,
        }

    output = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
    hint = ""
    if proc.returncode != 0:
        hint = "No runtime logs were captured. Press EN/RESET during probe, or hold BOOT+tap EN for bootloader check."
    return {
        "ok": proc.returncode == 0,
        "port": device,
        "baud": baud,
        "probe_mode": "runtime_then_bootloader",
        "return_code": proc.returncode,
        "tool_source": tool_source,
        "output": output[-4000:],
        "hint": hint,
        "runtime_capture_ok": True,
        "runtime_capture_error": "",
        "runtime_summary": runtime_summary,
        "runtime_log_tail": runtime_tail,
        "runtime_retry_errors": runtime_retry_errors[-12:],
        "reset_attempted": reset_attempted,
        "reset_ok": reset_ok,
        "reset_error": reset_error,
    }
