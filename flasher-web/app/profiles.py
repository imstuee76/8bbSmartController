from __future__ import annotations

import json
import re
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .ota import sign_firmware
from .storage import DATA_DIR, append_event

PROFILES_DIR = DATA_DIR / "firmware_profiles"


def _utc_ts() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", value.strip().lower()).strip("-")
    return slug[:40] if slug else "profile"


def _profile_folder_name(profile_name: str, created_at: str, profile_id: str) -> str:
    dt = created_at.replace("-", "").replace(":", "").replace("T", "_").replace(".", "_").replace("+00:00", "Z")
    return f"{dt}_{_safe_slug(profile_name)}_{profile_id[:8]}"


def _metadata_path(profile_dir: Path) -> Path:
    return profile_dir / "metadata.json"


def create_firmware_profile(
    *,
    firmware_dir: Path,
    profile_name: str,
    firmware_filename: str,
    version: str,
    device_type: str,
    settings: dict[str, Any],
    notes: str,
    shared_key: str,
) -> dict[str, Any]:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)

    source_firmware = firmware_dir / firmware_filename
    if not source_firmware.exists():
        raise FileNotFoundError(f"Firmware not found: {firmware_filename}")
    if source_firmware.is_dir():
        raise ValueError(f"Firmware path points to a directory: {firmware_filename}")
    if source_firmware.suffix.lower() != ".bin":
        raise ValueError(f"Firmware must be a .bin file: {firmware_filename}")

    signed = sign_firmware(source_firmware, version, device_type, shared_key)
    signed_manifest_path = Path(signed["manifest_path"])
    if not signed_manifest_path.exists():
        raise FileNotFoundError(f"Signed manifest not found: {signed_manifest_path}")

    profile_id = str(uuid.uuid4())
    created_at = _utc_ts()
    folder_name = _profile_folder_name(profile_name, created_at, profile_id)
    profile_dir = PROFILES_DIR / folder_name
    profile_dir.mkdir(parents=True, exist_ok=False)

    profile_firmware_name = source_firmware.name
    profile_manifest_name = signed_manifest_path.name
    shutil.copy2(source_firmware, profile_dir / profile_firmware_name)
    shutil.copy2(signed_manifest_path, profile_dir / profile_manifest_name)

    metadata = {
        "profile_id": profile_id,
        "profile_name": profile_name,
        "created_at": created_at,
        "firmware_filename": profile_firmware_name,
        "version": version,
        "device_type": device_type,
        "settings": settings,
        "notes": notes,
        "profile_folder": folder_name,
        "files": {
            "firmware": profile_firmware_name,
            "manifest": profile_manifest_name,
        },
        "manifest": signed["manifest"],
    }

    _metadata_path(profile_dir).write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    append_event(
        "firmware_profile_created",
        {
            "profile_id": profile_id,
            "profile_name": profile_name,
            "folder": folder_name,
            "firmware": profile_firmware_name,
            "version": version,
        },
    )
    return metadata


def list_firmware_profiles() -> list[dict[str, Any]]:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    items: list[dict[str, Any]] = []
    for child in sorted(PROFILES_DIR.iterdir(), reverse=True):
        if not child.is_dir():
            continue
        meta_path = _metadata_path(child)
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        items.append(
            {
                "profile_id": meta.get("profile_id", ""),
                "profile_name": meta.get("profile_name", ""),
                "created_at": meta.get("created_at", ""),
                "firmware_filename": meta.get("firmware_filename", ""),
                "version": meta.get("version", ""),
                "device_type": meta.get("device_type", ""),
                "profile_folder": meta.get("profile_folder", child.name),
            }
        )
    items.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    return items


def get_firmware_profile(profile_id: str) -> dict[str, Any] | None:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    for child in PROFILES_DIR.iterdir():
        if not child.is_dir():
            continue
        meta_path = _metadata_path(child)
        if not meta_path.exists():
            continue
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if meta.get("profile_id") == profile_id:
            return meta
    return None


def get_profile_file_paths(profile: dict[str, Any]) -> tuple[Path, Path]:
    folder = str(profile.get("profile_folder", "")).strip()
    files = profile.get("files") or {}
    firmware_name = str(files.get("firmware", "")).strip()
    manifest_name = str(files.get("manifest", "")).strip()
    if not folder or not firmware_name or not manifest_name:
        raise ValueError("Profile file metadata is incomplete")

    profile_dir = PROFILES_DIR / folder
    firmware_path = profile_dir / firmware_name
    manifest_path = profile_dir / manifest_name
    if not firmware_path.exists() or not manifest_path.exists():
        raise FileNotFoundError("Profile firmware or manifest file is missing")
    return firmware_path, manifest_path
