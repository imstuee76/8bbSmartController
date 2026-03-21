from __future__ import annotations

import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

from .storage import DATA_DIR, append_event

PROJECT_ROOT = Path(__file__).resolve().parents[2]
ESP_FW_DIR = PROJECT_ROOT / "esp32-firmware"
ESP_FW_BUILD_DIR = ESP_FW_DIR / "build"
ESP_FW_GENERATED_DEFAULTS = ESP_FW_DIR / "main" / "generated_defaults.h"
FIRMWARE_DIR = DATA_DIR / "firmware"
BUILD_LOG_DIR = DATA_DIR / "logs" / "firmware_builds"
APP_BIN_NAME = "esp32_smart_device.bin"
MSYS_WARNING_TEXT = "MSys/Mingw is no longer supported."


def _safe_slug(value: str, fallback: str) -> str:
    raw = re.sub(r"[^a-zA-Z0-9_-]+", "-", (value or "").strip().lower()).strip("-")
    if not raw:
        raw = fallback
    return raw[:48]


class FirmwareBuildError(RuntimeError):
    def __init__(self, message: str, build_id: str, log_file: Path) -> None:
        super().__init__(f"{message} (build_id={build_id}, log={log_file})")
        self.build_id = build_id
        self.log_file = log_file


def _summarize_command_output(
    *,
    step: str,
    return_code: int,
    raw_output: str,
    success_hint: str = "",
) -> str:
    lines = [ln.strip() for ln in str(raw_output or "").splitlines() if ln.strip()]
    kept: list[str] = []
    warnings: list[str] = []
    for line in lines:
        if MSYS_WARNING_TEXT.lower() in line.lower():
            warnings.append(line)
            continue
        kept.append(line)

    tail_lines = kept[-24:] if kept else []
    summary: list[str] = [f"{step}_return_code={return_code}"]
    if return_code == 0:
        summary.append(f"{step}_status=success")
    else:
        summary.append(f"{step}_status=failed")
    if success_hint:
        summary.append(success_hint)
    if warnings:
        summary.append("warning=ESP-IDF printed MSys/Mingw warning; build can still succeed with return_code=0")
    if tail_lines:
        summary.append("--- tail ---")
        summary.extend(tail_lines)
    elif warnings:
        summary.append("--- tail ---")
        summary.append(warnings[-1])
    return "\n".join(summary).strip()


def _utc_compact() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _append_log(log_file: Path, text: str) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as fp:
        fp.write(text.rstrip() + "\n")


def _c_escape(value: str) -> str:
    text = str(value or "")
    return text.replace("\\", "\\\\").replace('"', '\\"')


def _to_bool_flag(value: object) -> int:
    if isinstance(value, bool):
        return 1 if value else 0
    if isinstance(value, (int, float)):
        return 1 if int(value) != 0 else 0
    text = str(value or "").strip().lower()
    if text in ("1", "true", "yes", "on"):
        return 1
    return 0


def _to_int(value: object, fallback: int) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except Exception:
        return fallback


def _clamp_int(value: int, min_val: int, max_val: int) -> int:
    if value < min_val:
        return min_val
    if value > max_val:
        return max_val
    return value


def _extract_relay_defaults(defaults: dict[str, object]) -> tuple[int, list[int]]:
    default_gpio = [16, 17, 18, 19, -1, -1, -1, -1]
    source: object = defaults
    if isinstance(defaults.get("type_settings"), dict):
        source = defaults.get("type_settings")

    relay_count = 4
    relay_gpio: list[int] = default_gpio.copy()

    if isinstance(source, dict):
        relay_count = _clamp_int(_to_int(source.get("relay_count"), relay_count), 1, 8)

        raw_gpio = source.get("relay_gpio")
        if not isinstance(raw_gpio, list):
            relays = source.get("relays")
            if isinstance(relays, list):
                raw_gpio = []
                for item in relays:
                    if isinstance(item, dict):
                        raw_gpio.append(item.get("gpio", -1))
                    else:
                        raw_gpio.append(-1)

        if isinstance(raw_gpio, list):
            parsed: list[int] = []
            for idx in range(8):
                raw = raw_gpio[idx] if idx < len(raw_gpio) else -1
                pin = _to_int(raw, -1)
                if pin == -1:
                    parsed.append(-1)
                else:
                    parsed.append(_clamp_int(pin, 0, 39))
            relay_gpio = parsed

    return relay_count, relay_gpio


def _write_generated_defaults(defaults: dict[str, object], log_file: Path) -> None:
    relay_count, relay_gpio = _extract_relay_defaults(defaults)
    merged = {
        "name": str(defaults.get("name", "8bb-esp32") or "8bb-esp32"),
        "type": str(defaults.get("type", "relay_switch") or "relay_switch"),
        "passcode": str(defaults.get("passcode", "1234") or "1234"),
        "wifi_ssid": str(defaults.get("wifi_ssid", "") or ""),
        "wifi_pass": str(defaults.get("wifi_pass", "") or ""),
        "ap_ssid": str(defaults.get("ap_ssid", "8bb-device-setup") or "8bb-device-setup"),
        "ap_pass": str(defaults.get("ap_pass", "12345678") or "12345678"),
        "use_static_ip": _to_bool_flag(defaults.get("use_static_ip", 0)),
        "static_ip": str(defaults.get("static_ip", "") or ""),
        "gateway": str(defaults.get("gateway", "") or ""),
        "subnet_mask": str(defaults.get("subnet_mask", "") or ""),
        "ota_key": str(defaults.get("ota_key", "8bb-change-this-ota-key") or "8bb-change-this-ota-key"),
        "relay_count": relay_count,
        "relay_gpio": relay_gpio,
    }

    content = "\n".join(
        [
            "#pragma once",
            "",
            "// Auto-generated by flasher build endpoint. Do not edit manually.",
            f'#define FW_DEFAULT_NAME "{_c_escape(merged["name"])}"',
            f'#define FW_DEFAULT_TYPE "{_c_escape(merged["type"])}"',
            f'#define FW_DEFAULT_PASSCODE "{_c_escape(merged["passcode"])}"',
            f'#define FW_DEFAULT_WIFI_SSID "{_c_escape(merged["wifi_ssid"])}"',
            f'#define FW_DEFAULT_WIFI_PASS "{_c_escape(merged["wifi_pass"])}"',
            f'#define FW_DEFAULT_AP_SSID "{_c_escape(merged["ap_ssid"])}"',
            f'#define FW_DEFAULT_AP_PASS "{_c_escape(merged["ap_pass"])}"',
            f'#define FW_DEFAULT_USE_STATIC_IP {int(merged["use_static_ip"])}',
            f'#define FW_DEFAULT_STATIC_IP "{_c_escape(merged["static_ip"])}"',
            f'#define FW_DEFAULT_GATEWAY "{_c_escape(merged["gateway"])}"',
            f'#define FW_DEFAULT_SUBNET_MASK "{_c_escape(merged["subnet_mask"])}"',
            f'#define FW_DEFAULT_OTA_KEY "{_c_escape(merged["ota_key"])}"',
            f'#define FW_DEFAULT_RELAY_COUNT {int(merged["relay_count"])}',
            f'#define FW_DEFAULT_RELAY_GPIO_1 {int(merged["relay_gpio"][0])}',
            f'#define FW_DEFAULT_RELAY_GPIO_2 {int(merged["relay_gpio"][1])}',
            f'#define FW_DEFAULT_RELAY_GPIO_3 {int(merged["relay_gpio"][2])}',
            f'#define FW_DEFAULT_RELAY_GPIO_4 {int(merged["relay_gpio"][3])}',
            f'#define FW_DEFAULT_RELAY_GPIO_5 {int(merged["relay_gpio"][4])}',
            f'#define FW_DEFAULT_RELAY_GPIO_6 {int(merged["relay_gpio"][5])}',
            f'#define FW_DEFAULT_RELAY_GPIO_7 {int(merged["relay_gpio"][6])}',
            f'#define FW_DEFAULT_RELAY_GPIO_8 {int(merged["relay_gpio"][7])}',
            "",
        ]
    )
    ESP_FW_GENERATED_DEFAULTS.parent.mkdir(parents=True, exist_ok=True)
    ESP_FW_GENERATED_DEFAULTS.write_text(content, encoding="utf-8")
    _append_log(
        log_file,
        "generated_defaults="
        + json.dumps(
            {
                "name": merged["name"],
                "type": merged["type"],
                "wifi_ssid": merged["wifi_ssid"],
                "ap_ssid": merged["ap_ssid"],
                "use_static_ip": int(merged["use_static_ip"]),
                "static_ip": merged["static_ip"],
                "relay_count": int(merged["relay_count"]),
                "relay_gpio": merged["relay_gpio"],
            }
        ),
    )


def _dedupe_keep_order(values: list[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for value in values:
        key = value.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(value)
    return out


def _collect_idf_tool_paths(tools_root: Path) -> list[str]:
    if not tools_root.exists():
        return []
    base = tools_root
    if (tools_root / "tools").exists():
        base = tools_root / "tools"
    entries: list[str] = []
    patterns = [
        "cmake/*/bin",
        "ninja/*",
        "idf-exe/*",
        "idf-git/*/cmd",
        "idf-git/*/bin",
        "xtensa-esp-elf/*/*/bin",
        "riscv32-esp-elf/*/*/bin",
        "esp32ulp-elf/*/*/bin",
        "esp-clang/*/*/bin",
        "openocd-esp32/*/*/bin",
        "dfu-util/*/*/bin",
        "ccache/*",
    ]
    for pattern in patterns:
        for raw in sorted(glob.glob(str(base / pattern))):
            p = Path(raw)
            if p.exists() and p.is_dir():
                entries.append(str(p.resolve()))

    for bin_dir in base.rglob("bin"):
        if not bin_dir.is_dir():
            continue
        rel_parts = bin_dir.relative_to(base).parts
        if len(rel_parts) > 6:
            continue
        if list(bin_dir.glob("*.exe")):
            entries.append(str(bin_dir.resolve()))
    return _dedupe_keep_order(entries)


def _prepend_path(env: dict[str, str], entries: list[str]) -> None:
    if not entries:
        return
    path_key = "PATH"
    for key in env.keys():
        if key.lower() == "path":
            path_key = key
            break
    current = env.get(path_key, "")
    parts = [p for p in current.split(os.pathsep) if p]
    merged = _dedupe_keep_order(entries + parts)
    env[path_key] = os.pathsep.join(merged)


def _extract_idf_script_path(cmd: list[str]) -> Path | None:
    for token in cmd:
        raw = str(token).strip().strip('"')
        if raw.lower().endswith("idf.py"):
            p = Path(raw)
            if p.exists():
                return p.resolve()
    return None


def _infer_idf_env(cmd: list[str]) -> dict[str, str]:
    env: dict[str, str] = {}
    for k in ("IDF_PATH", "IDF_TOOLS_PATH", "IDF_PYTHON_ENV_PATH", "ESP_ROM_ELF_DIR"):
        v = os.environ.get(k, "").strip()
        if v:
            env[k] = v
    script = _extract_idf_script_path(cmd)
    tools_root_hint: Path | None = None
    if script:
        idf_path = script.parent.parent
        env["IDF_PATH"] = str(idf_path)
        for parent in script.parents:
            if parent.name.lower() == "frameworks":
                tools_root = parent.parent
                if (tools_root / "python_env").exists():
                    env["IDF_TOOLS_PATH"] = str(tools_root)
                    tools_root_hint = tools_root
                break
        if not env.get("IDF_TOOLS_PATH"):
            home_tools = Path.home() / ".espressif"
            if home_tools.exists():
                env["IDF_TOOLS_PATH"] = str(home_tools)
                tools_root_hint = home_tools

    if cmd:
        py = Path(str(cmd[0]).strip().strip('"'))
        if py.exists() and py.name.lower() in ("python.exe", "python"):
            scripts_dir = py.parent
            if scripts_dir.name.lower() in ("scripts", "bin"):
                py_env = scripts_dir.parent
                env["IDF_PYTHON_ENV_PATH"] = str(py_env)

    tools_root = Path(env["IDF_TOOLS_PATH"]) if env.get("IDF_TOOLS_PATH") else tools_root_hint
    if tools_root and tools_root.exists():
        rom_candidates = sorted((tools_root / "tools" / "esp-rom-elfs").glob("*"))
        rom_dirs = [p for p in rom_candidates if p.is_dir()]
        if rom_dirs:
            rom_dirs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
            env["ESP_ROM_ELF_DIR"] = str(rom_dirs[0])
    return env


def _run_idf(cmd: list[str], log_file: Path, env_extra: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    _append_log(log_file, f"$ {' '.join(cmd)}")
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
        for k, v in env_extra.items():
            _append_log(log_file, f"env {k}={v}")
        tools_root = Path(env_extra.get("IDF_TOOLS_PATH", "")).resolve() if env_extra.get("IDF_TOOLS_PATH") else None
        if tools_root:
            tool_paths = _collect_idf_tool_paths(tools_root)
            _prepend_path(env, tool_paths)
            if tool_paths:
                _append_log(log_file, "env PATH+idf_tools=" + ";".join(tool_paths))
                path_key = next((k for k in env.keys() if k.lower() == "path"), "PATH")
                _append_log(log_file, f"env path_key={path_key}")
    return subprocess.run(
        cmd,
        cwd=str(ESP_FW_DIR),
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


def _is_missing_constraints_error(output: str) -> bool:
    text = (output or "").lower()
    return "espidf.constraints" in text and "doesn't exist" in text


def _detect_constraints_file_for_idf_cmd(idf_cmd: list[str], log_file: Path) -> Path | None:
    if not idf_cmd:
        return None
    probe_cmd = [*idf_cmd, "--version"]
    _append_log(log_file, f"$ {' '.join(probe_cmd)}")
    proc = subprocess.run(
        probe_cmd,
        cwd=str(ESP_FW_DIR),
        capture_output=True,
        text=True,
        env=os.environ.copy(),
        check=False,
    )
    raw = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
    _append_log(log_file, f"idf_version_probe_return_code={proc.returncode}")
    _append_log(log_file, f"idf_version_probe_output={(raw[-400:] if raw else '<empty>')}")
    m = re.search(r"v(\d+)\.(\d+)(?:\.\d+)?", raw, flags=re.IGNORECASE)
    if not m:
        return None
    mm = f"{m.group(1)}.{m.group(2)}"
    return Path.home() / ".espressif" / f"espidf.constraints.v{mm}.txt"


def _run_idf_install_repair(idf_cmd: list[str], log_file: Path) -> bool:
    script = _extract_idf_script_path(idf_cmd)
    if not script:
        _append_log(log_file, "repair_install=skipped reason=idf_script_not_resolved")
        return False
    idf_root = script.parent.parent
    if os.name == "nt":
        install_candidates = [idf_root / "install.bat", idf_root / "install.ps1", idf_root / "install.sh"]
    else:
        install_candidates = [idf_root / "install.sh", idf_root / "install.bat", idf_root / "install.ps1"]
    install_script = next((p for p in install_candidates if p.exists()), None)
    if not install_script:
        _append_log(
            log_file,
            "repair_install=skipped reason=missing_install_script "
            + "candidates="
            + ", ".join(str(p) for p in install_candidates),
        )
        return False

    suffix = install_script.suffix.lower()
    if suffix in (".bat", ".cmd"):
        cmd = ["cmd.exe", "/c", str(install_script), "esp32"]
    elif suffix == ".ps1":
        cmd = ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File", str(install_script), "esp32"]
    else:
        cmd = [str(install_script), "esp32"]
    _append_log(log_file, f"repair_install_script={install_script}")
    _append_log(log_file, f"$ {' '.join(cmd)}")
    clean_env = os.environ.copy()
    for key in ("IDF_PYTHON_ENV_PATH", "IDF_CMD", "IDF_PY_PATH", "ESP_IDF_PYTHON", "IDF_PATH"):
        clean_env.pop(key, None)
    proc = subprocess.run(
        cmd,
        cwd=str(idf_root),
        capture_output=True,
        text=True,
        env=clean_env,
        check=False,
    )
    raw = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
    _append_log(log_file, "--- idf install repair stdout/stderr ---")
    _append_log(log_file, raw or "<empty>")
    _append_log(log_file, f"repair_install_return_code={proc.returncode}")
    return proc.returncode == 0


def _candidate_idf_scripts() -> list[Path]:
    candidates: list[Path] = []
    idf_path = os.environ.get("IDF_PATH", "").strip()
    if idf_path:
        p = Path(idf_path) / "tools" / "idf.py"
        candidates.append(p)

    user_profile = Path(os.environ.get("USERPROFILE", "C:\\Users\\Public"))
    home = Path(os.environ.get("HOME", str(Path.home())))
    patterns = [
        "C:/Espressif/frameworks/*/tools/idf.py",
        str(user_profile / ".espressif" / "frameworks" / "*" / "tools" / "idf.py"),
        str(user_profile / "Espressif" / "frameworks" / "*" / "tools" / "idf.py"),
        str(home / "esp" / "esp-idf" / "tools" / "idf.py"),
        str(home / "esp-idf" / "tools" / "idf.py"),
        str(home / ".espressif" / "frameworks" / "*" / "tools" / "idf.py"),
        "/opt/esp-idf/tools/idf.py",
    ]
    for pattern in patterns:
        for raw in sorted(glob.glob(pattern)):
            candidates.append(Path(raw))

    out: list[Path] = []
    for p in candidates:
        if p.exists() and p.is_file():
            out.append(p.resolve())
    return out


def _parse_env_cmd(raw: str) -> list[str]:
    text = raw.strip()
    if not text:
        return []
    return shlex.split(text, posix=False)


def _extract_mm_from_text(raw: str) -> str | None:
    m = re.search(r"(\d+)\.(\d+)", str(raw or ""))
    if not m:
        return None
    return f"{m.group(1)}.{m.group(2)}"


def _guess_mm_from_python_path(raw: str) -> str | None:
    token = str(raw or "").strip().strip('"')
    if not token:
        return None
    m = re.search(r"idf(\d+\.\d+)", token, flags=re.IGNORECASE)
    if m:
        return m.group(1)
    m = re.search(r"idf[-_]?v?(\d+\.\d+)", token, flags=re.IGNORECASE)
    if m:
        return m.group(1)
    return None


def _guess_idf_mm_from_script(script_path: Path) -> str | None:
    script = script_path.resolve()
    root = script.parent.parent

    from_path = _extract_mm_from_text(str(root))
    if from_path:
        return from_path

    version_txt = root / "version.txt"
    if version_txt.exists():
        try:
            txt = version_txt.read_text(encoding="utf-8", errors="ignore")
            mm = _extract_mm_from_text(txt)
            if mm:
                return mm
        except Exception:
            pass

    version_cmake = root / "tools" / "cmake" / "version.cmake"
    if version_cmake.exists():
        try:
            txt = version_cmake.read_text(encoding="utf-8", errors="ignore")
            major = re.search(r"IDF_VERSION_MAJOR\s+(\d+)", txt)
            minor = re.search(r"IDF_VERSION_MINOR\s+(\d+)", txt)
            if major and minor:
                return f"{major.group(1)}.{minor.group(1)}"
        except Exception:
            pass
    return None


def _token_is_probably_windows_path(token: str) -> bool:
    t = str(token or "").strip().strip('"')
    if not t:
        return False
    if re.match(r"^[A-Za-z]:\\", t):
        return True
    if "\\" in t and "/" not in t:
        return True
    if t.lower().endswith(".exe"):
        return True
    return False


def _is_cmd_runnable(cmd: list[str]) -> bool:
    if not cmd:
        return False
    first = str(cmd[0]).strip().strip('"')
    if not first:
        return False
    if Path(first).exists():
        return True
    if shutil.which(first):
        return True
    return False


def _pick_idf_python(preferred_mm: str | None = None) -> str:
    preferred_mm = _extract_mm_from_text(preferred_mm or "")

    def _score(path_text: str) -> int:
        if not preferred_mm:
            return 0
        mm = _guess_mm_from_python_path(path_text) or ""
        if mm == preferred_mm:
            return 3
        if preferred_mm.replace(".", "") in path_text.replace(".", ""):
            return 2
        return 0

    env_python = os.environ.get("ESP_IDF_PYTHON", "").strip()
    if env_python and Path(env_python).exists() and (_score(env_python) > 0 or not preferred_mm):
        return env_python

    idf_py_env = os.environ.get("IDF_PYTHON_ENV_PATH", "").strip()
    if idf_py_env:
        linux_py = Path(idf_py_env) / "bin" / "python"
        win_py = Path(idf_py_env) / "Scripts" / "python.exe"
        if linux_py.exists() and linux_py.is_file() and (_score(str(linux_py)) > 0 or not preferred_mm):
            return str(linux_py)
        if win_py.exists() and win_py.is_file() and (_score(str(win_py)) > 0 or not preferred_mm):
            return str(win_py)

    patterns = [
        "C:/Espressif/python_env/*/Scripts/python.exe",
        "C:/Espressif/tools/idf-python/*/python.exe",
        str(Path.home() / ".espressif" / "python_env" / "*" / "bin" / "python"),
        str(Path.home() / "esp" / "python_env" / "*" / "bin" / "python"),
    ]
    found: list[Path] = []
    for pattern in patterns:
        for raw in sorted(glob.glob(pattern)):
            p = Path(raw)
            if p.exists() and p.is_file():
                found.append(p)
    if found:
        found.sort(key=lambda p: (_score(str(p)), p.stat().st_mtime), reverse=True)
        return str(found[0])

    return sys.executable


def _find_eim_cmd() -> list[str]:
    direct = shutil.which("eim") or shutil.which("eim.exe")
    if direct:
        return [direct]
    user_profile = Path(os.environ.get("USERPROFILE", "C:\\Users\\Public"))
    winget_eim = (
        user_profile
        / "AppData"
        / "Local"
        / "Microsoft"
        / "WinGet"
        / "Packages"
        / "Espressif.EIM-CLI_Microsoft.Winget.Source_8wekyb3d8bbwe"
        / "eim.exe"
    )
    if winget_eim.exists():
        return [str(winget_eim)]
    return []


def _find_idf_cmd() -> list[str]:
    env_cmd = _parse_env_cmd(os.environ.get("IDF_CMD", ""))
    if env_cmd:
        # Avoid stale Windows-only command strings when backend is running on Linux.
        if os.name != "nt" and any(_token_is_probably_windows_path(tok) for tok in env_cmd):
            env_cmd = []
        elif _is_cmd_runnable(env_cmd):
            script = _extract_idf_script_path(env_cmd)
            if script and len(env_cmd) >= 2:
                preferred_mm = _guess_idf_mm_from_script(script)
                current_mm = _guess_mm_from_python_path(env_cmd[0])
                if preferred_mm and current_mm and preferred_mm != current_mm:
                    return [_pick_idf_python(preferred_mm), str(script)]
            return env_cmd
        else:
            env_cmd = []

    for tool_name in ("idf.py", "idf.py.exe", "idf.bat", "idf"):
        tool = shutil.which(tool_name)
        if tool:
            return [tool]

    env_script = os.environ.get("IDF_PY_PATH", "").strip()
    if env_script:
        script_path = Path(env_script)
        if script_path.exists():
            preferred_mm = _guess_idf_mm_from_script(script_path)
            idf_python = _pick_idf_python(preferred_mm)
            return [idf_python, str(script_path)]

    for script_path in _candidate_idf_scripts():
        preferred_mm = _guess_idf_mm_from_script(script_path)
        idf_python = _pick_idf_python(preferred_mm)
        return [idf_python, str(script_path)]

    eim_cmd = _find_eim_cmd()
    if eim_cmd:
        return [*eim_cmd, "run", "--", "idf.py"]

    raise RuntimeError(
        "ESP-IDF command not found. Set and restart backend, for example:\n"
        "Linux: IDF_CMD='python3 /home/<user>/esp/esp-idf/tools/idf.py'\n"
        "Windows: IDF_CMD='idf.py' or IDF_PY_PATH='C:\\path\\to\\idf.py' and optional ESP_IDF_PYTHON='C:\\path\\to\\python.exe'."
    )


def _resolve_idf_cmd_and_env(log_file: Path, *, context: str) -> tuple[list[str], dict[str, str]]:
    idf_cmd = _find_idf_cmd()
    _append_log(log_file, f"idf_cmd[{context}]={' '.join(idf_cmd)}")
    idf_env = _infer_idf_env(idf_cmd)
    if idf_env:
        _append_log(
            log_file,
            "idf_env_overrides"
            + f"[{context}]="
            + ", ".join(f"{k}={v}" for k, v in idf_env.items()),
        )
    return idf_cmd, idf_env


def build_firmware(
    *,
    profile_name: str,
    version: str,
    device_type: str,
    defaults: dict[str, object] | None = None,
) -> dict[str, str]:
    build_id = str(uuid.uuid4())
    ts = _utc_compact()
    name_slug = _safe_slug(profile_name, "profile")
    log_file = BUILD_LOG_DIR / f"{ts}_{name_slug}_{build_id[:8]}.log"
    _append_log(log_file, f"[{ts}] 8bb firmware build started")
    _append_log(log_file, f"build_id={build_id}")
    _append_log(log_file, f"profile_name={profile_name}")
    _append_log(log_file, f"version={version}")
    _append_log(log_file, f"device_type={device_type}")
    _append_log(log_file, f"firmware_dir={ESP_FW_DIR}")

    append_event(
        "firmware_build_started",
        {
            "build_id": build_id,
            "log_file": str(log_file),
            "profile_name": profile_name,
            "version": version,
            "device_type": device_type,
        },
    )

    try:
        if not ESP_FW_DIR.exists():
            raise FileNotFoundError(f"Firmware source folder not found: {ESP_FW_DIR}")

        _write_generated_defaults(defaults or {}, log_file)

        idf_cmd, idf_env = _resolve_idf_cmd_and_env(log_file, context="initial")

        constraints_file = _detect_constraints_file_for_idf_cmd(idf_cmd, log_file)
        if constraints_file and not constraints_file.exists():
            _append_log(log_file, f"repair_install_detected=missing_constraints_file path={constraints_file}")
            repaired_pre = _run_idf_install_repair(idf_cmd, log_file)
            if repaired_pre:
                _append_log(log_file, "repair_install=success (pre-build)")
                idf_cmd, idf_env = _resolve_idf_cmd_and_env(log_file, context="post-repair-pre")
            else:
                _append_log(log_file, "repair_install=failed (pre-build)")

        build = _run_idf([*idf_cmd, "build"], log_file, env_extra=idf_env)
        build_raw = ((build.stdout or "") + "\n" + (build.stderr or "")).strip()
        repaired = False
        if build.returncode != 0 and _is_missing_constraints_error(build_raw):
            _append_log(log_file, "repair_install_detected=missing_constraints")
            repaired = _run_idf_install_repair(idf_cmd, log_file)
            if repaired:
                _append_log(log_file, "repair_install=success retrying_build")
                idf_cmd, idf_env = _resolve_idf_cmd_and_env(log_file, context="post-repair-retry")
                build = _run_idf([*idf_cmd, "build"], log_file, env_extra=idf_env)
                build_raw = ((build.stdout or "") + "\n" + (build.stderr or "")).strip()
            else:
                _append_log(log_file, "repair_install=failed")
        build_log = _summarize_command_output(
            step="build",
            return_code=build.returncode,
            raw_output=build_raw,
            success_hint="idf.py build finished",
        )
        _append_log(log_file, "--- idf.py build stdout/stderr ---")
        _append_log(log_file, build_raw or "<empty>")
        _append_log(log_file, f"build_return_code={build.returncode}")
        if build.returncode != 0:
            raise RuntimeError(f"idf.py build failed with exit code {build.returncode}")

        app_bin = ESP_FW_BUILD_DIR / APP_BIN_NAME
        if not app_bin.exists():
            raise FileNotFoundError(f"Built app firmware not found: {app_bin}")

        FIRMWARE_DIR.mkdir(parents=True, exist_ok=True)
        version_slug = _safe_slug(version, "1-0-0")
        type_slug = _safe_slug(device_type, "device")
        base = f"{ts}_{name_slug}_{type_slug}_v{version_slug}"

        ota_name = f"{base}_ota.bin"
        ota_path = FIRMWARE_DIR / ota_name
        shutil.copy2(app_bin, ota_path)
        _append_log(log_file, f"copied_ota={ota_path}")

        serial_name = ""
        merge_log = ""
        merge_output = ESP_FW_BUILD_DIR / "merged-flash.bin"
        merge = _run_idf([*idf_cmd, "merge-bin", "-o", str(merge_output)], log_file, env_extra=idf_env)
        merge_raw = ((merge.stdout or "") + "\n" + (merge.stderr or "")).strip()
        merge_log = _summarize_command_output(
            step="merge",
            return_code=merge.returncode,
            raw_output=merge_raw,
            success_hint="idf.py merge-bin finished",
        )
        _append_log(log_file, "--- idf.py merge-bin stdout/stderr ---")
        _append_log(log_file, merge_raw or "<empty>")
        _append_log(log_file, f"merge_return_code={merge.returncode}")
        if merge.returncode == 0 and merge_output.exists():
            serial_name = f"{base}_full.bin"
            serial_path = FIRMWARE_DIR / serial_name
            shutil.copy2(merge_output, serial_path)
            _append_log(log_file, f"copied_serial={serial_path}")
        else:
            _append_log(log_file, "serial_full_bin_not_generated")

        append_event(
            "firmware_built",
            {
                "build_id": build_id,
                "log_file": str(log_file),
                "ota_firmware": ota_name,
                "serial_firmware": serial_name,
                "profile_name": profile_name,
                "version": version,
                "device_type": device_type,
            },
        )
        _append_log(log_file, "status=success")
        return {
            "build_id": build_id,
            "log_file": str(log_file),
            "ota_firmware_filename": ota_name,
            "serial_firmware_filename": serial_name,
            "build_log": build_log[-3000:],
            "merge_log": merge_log[-2000:],
        }
    except Exception as exc:
        _append_log(log_file, f"status=failed error={exc}")
        append_event(
            "firmware_build_failed",
            {
                "build_id": build_id,
                "log_file": str(log_file),
                "error": str(exc),
            },
        )
        raise FirmwareBuildError(str(exc), build_id, log_file) from exc
