#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "shared" / "version.json"
PUBSPEC_FILE = ROOT / "controller-app" / "pubspec.yaml"
CONTROLLER_VERSION_DART = ROOT / "controller-app" / "lib" / "app_version.dart"


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def parse_semver(value: str) -> tuple[int, int, int]:
    m = re.match(r"^\s*(\d+)\.(\d+)\.(\d+)\s*$", (value or "").strip())
    if not m:
        return 0, 1, 0
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def bump_patch(value: str) -> str:
    major, minor, patch = parse_semver(value)
    patch += 1
    return f"{major}.{minor}.{patch}"


def default_manifest() -> dict[str, Any]:
    return {
        "controller": {"version": "0.1.0", "build": 1},
        "flasher": {"version": "0.2.0", "build": 1},
        "updated_at": utc_now(),
    }


def load_manifest() -> dict[str, Any]:
    if not VERSION_FILE.exists():
        return default_manifest()
    try:
        raw = json.loads(VERSION_FILE.read_text(encoding="utf-8"))
    except Exception:
        return default_manifest()
    if not isinstance(raw, dict):
        return default_manifest()
    manifest = default_manifest()
    for name in ("controller", "flasher"):
        section = raw.get(name, {})
        if isinstance(section, dict):
            version = str(section.get("version", manifest[name]["version"]))
            build_raw = section.get("build", manifest[name]["build"])
            try:
                build = int(build_raw)
            except Exception:
                build = int(manifest[name]["build"])
            manifest[name] = {"version": version, "build": max(1, build)}
    manifest["updated_at"] = str(raw.get("updated_at", utc_now()))
    return manifest


def write_manifest(manifest: dict[str, Any]) -> None:
    VERSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    VERSION_FILE.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def update_pubspec(controller_version: str, controller_build: int) -> None:
    if not PUBSPEC_FILE.exists():
        return
    content = PUBSPEC_FILE.read_text(encoding="utf-8")
    version_line = f"version: {controller_version}+{controller_build}"
    updated = re.sub(r"(?m)^version:\s*.+$", version_line, content)
    PUBSPEC_FILE.write_text(updated, encoding="utf-8")


def update_controller_version_file(controller_version: str, controller_build: int) -> None:
    display = f"{controller_version}+{controller_build}"
    text = (
        f'const String controllerVersion = "{controller_version}";\n'
        f"const int controllerBuild = {controller_build};\n"
        f'const String controllerDisplayVersion = "{display}";\n'
    )
    CONTROLLER_VERSION_DART.parent.mkdir(parents=True, exist_ok=True)
    CONTROLLER_VERSION_DART.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Bump controller+flasher app versions.")
    parser.add_argument(
        "--patch",
        action="store_true",
        help="Increment semantic patch version and build for both apps.",
    )
    parser.add_argument(
        "--build-only",
        action="store_true",
        help="Increment build number only.",
    )
    args = parser.parse_args()

    manifest = load_manifest()
    for component in ("controller", "flasher"):
        current = manifest[component]
        if args.patch or not args.build_only:
            current["version"] = bump_patch(str(current.get("version", "0.1.0")))
        current["build"] = int(current.get("build", 1)) + 1
        manifest[component] = current

    manifest["updated_at"] = utc_now()
    write_manifest(manifest)
    update_pubspec(manifest["controller"]["version"], int(manifest["controller"]["build"]))
    update_controller_version_file(manifest["controller"]["version"], int(manifest["controller"]["build"]))

    print(
        json.dumps(
            {
                "controller": manifest["controller"],
                "flasher": manifest["flasher"],
                "updated_at": manifest["updated_at"],
                "version_file": str(VERSION_FILE),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
