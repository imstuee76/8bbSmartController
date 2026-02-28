#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BACKEND_DIR = ROOT / "flasher-web"
CONTROLLER_DIR = ROOT / "controller-app"
BACKEND_REQ = BACKEND_DIR / "requirements.txt"


def log(msg: str) -> None:
    print(f"[8bb-run] {msg}", flush=True)


def run(cmd: list[str], cwd: Path | None = None, dry_run: bool = False) -> None:
    where = f" (cwd={cwd})" if cwd else ""
    log(f"$ {' '.join(cmd)}{where}")
    if dry_run:
        return
    subprocess.run(cmd, cwd=str(cwd) if cwd else None, check=True)


def has_pip(py: str) -> bool:
    result = subprocess.run([py, "-m", "pip", "--version"], capture_output=True, text=True)
    return result.returncode == 0


def ensure_pip(py: str, dry_run: bool = False) -> None:
    if has_pip(py):
        return
    log("pip not found for selected Python. Attempting ensurepip...")
    run([py, "-m", "ensurepip", "--upgrade"], cwd=ROOT, dry_run=dry_run)
    if not dry_run and not has_pip(py):
        raise RuntimeError(
            f"Python interpreter '{py}' has no working pip. "
            "Use a working Python (example: C:\\Program Files\\Python313\\python.exe)."
        )


def must_have_command(name: str, hint: str) -> None:
    if shutil.which(name):
        return
    raise RuntimeError(f"Missing command '{name}'. {hint}")


def ensure_backend_installed(py: str, dry_run: bool = False) -> None:
    if not BACKEND_REQ.exists():
        raise RuntimeError(f"Missing requirements file: {BACKEND_REQ}")
    ensure_pip(py, dry_run=dry_run)
    run([py, "-m", "pip", "install", "--user", "--upgrade", "-r", str(BACKEND_REQ)], cwd=ROOT, dry_run=dry_run)


def ensure_controller_installed(dry_run: bool = False) -> None:
    must_have_command("flutter", "Install Flutter and add it to PATH.")
    run(["flutter", "pub", "get"], cwd=CONTROLLER_DIR, dry_run=dry_run)


def start_backend(py: str, host: str, port: int, reload_mode: bool, dry_run: bool = False) -> subprocess.Popen[str] | None:
    cmd = [py, "-m", "uvicorn", "app.main:app", "--host", host, "--port", str(port)]
    if reload_mode:
        cmd.append("--reload")
    if dry_run:
        run(cmd, cwd=BACKEND_DIR, dry_run=True)
        return None
    log(f"$ {' '.join(cmd)} (cwd={BACKEND_DIR})")
    return subprocess.Popen(cmd, cwd=str(BACKEND_DIR), text=True)


def run_controller(device: str, dry_run: bool = False) -> None:
    cmd = ["flutter", "run"]
    if device.strip():
        cmd.extend(["-d", device.strip()])
    run(cmd, cwd=CONTROLLER_DIR, dry_run=dry_run)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Separated launcher for 8bb apps (no venv required).",
    )
    parser.add_argument(
        "--mode",
        choices=["backend", "controller"],
        default="backend",
        help="What to run. Apps are intentionally separated.",
    )
    parser.add_argument("--host", default="0.0.0.0", help="Backend bind host.")
    parser.add_argument("--port", type=int, default=8088, help="Backend bind port.")
    parser.add_argument(
        "--device",
        default="",
        help="Flutter device id (example: linux, windows, chrome). Empty = Flutter default.",
    )
    parser.add_argument(
        "--skip-install",
        action="store_true",
        help="Skip dependency install/update step.",
    )
    parser.add_argument(
        "--reload",
        action="store_true",
        help="Enable backend auto-reload (off by default for stable sessions).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands only.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    py = sys.executable
    if not py:
        raise RuntimeError("Python interpreter not found.")

    if not args.skip_install:
        if args.mode == "backend":
            log("Installing/updating backend Python packages (global user site, no venv)...")
            ensure_backend_installed(py, dry_run=args.dry_run)
        if args.mode == "controller":
            log("Installing/updating Flutter packages...")
            ensure_controller_installed(dry_run=args.dry_run)

    if args.mode == "backend":
        proc = start_backend(py, args.host, args.port, reload_mode=args.reload, dry_run=args.dry_run)
        if proc is None:
            return 0
        return proc.wait()

    run_controller(args.device, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("Stopped by user.")
        raise SystemExit(130)
    except Exception as exc:
        log(f"ERROR: {exc}")
        raise SystemExit(1)
