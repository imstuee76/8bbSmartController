from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[2]
VERSION_FILE = ROOT_DIR / "shared" / "version.json"


def _default_manifest() -> dict[str, Any]:
    return {
        "controller": {"version": "0.1.0", "build": 1},
        "flasher": {"version": "0.2.0", "build": 1},
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }


def load_version_manifest() -> dict[str, Any]:
    manifest = _default_manifest()
    if not VERSION_FILE.exists():
        return manifest
    try:
        raw = json.loads(VERSION_FILE.read_text(encoding="utf-8"))
    except Exception:
        return manifest
    if not isinstance(raw, dict):
        return manifest
    controller = raw.get("controller")
    flasher = raw.get("flasher")
    if isinstance(controller, dict):
        manifest["controller"] = {
            "version": str(controller.get("version", manifest["controller"]["version"])),
            "build": int(controller.get("build", manifest["controller"]["build"])),
        }
    if isinstance(flasher, dict):
        manifest["flasher"] = {
            "version": str(flasher.get("version", manifest["flasher"]["version"])),
            "build": int(flasher.get("build", manifest["flasher"]["build"])),
        }
    manifest["updated_at"] = str(raw.get("updated_at", manifest["updated_at"]))
    return manifest


def format_component_version(component: dict[str, Any]) -> str:
    version = str(component.get("version", "0.0.0")).strip() or "0.0.0"
    try:
        build = int(component.get("build", 0))
    except Exception:
        build = 0
    return f"{version}+{build}"


def flasher_display_version() -> str:
    manifest = load_version_manifest()
    return format_component_version(manifest.get("flasher", {}))

