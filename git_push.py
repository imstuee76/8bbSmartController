#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
LOG_DIR = DATA_DIR / "logs" / "git" / "sessions"


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def ensure_log_files() -> tuple[Path, Path]:
    session_dir = LOG_DIR / f"git-{utc_stamp()}"
    session_dir.mkdir(parents=True, exist_ok=True)
    day = datetime.now(timezone.utc).strftime("%Y%m%d")
    activity = session_dir / f"activity-{day}.log"
    errors = session_dir / f"errors-{day}.log"
    return activity, errors


ACTIVITY_LOG, ERROR_LOG = ensure_log_files()


def log(message: str) -> None:
    line = f"[8bb-git] {message}"
    print(line, flush=True)
    with ACTIVITY_LOG.open("a", encoding="utf-8") as fp:
        fp.write(line + "\n")


def log_error(message: str) -> None:
    line = f"[8bb-git] ERROR: {message}"
    print(line, file=sys.stderr, flush=True)
    with ERROR_LOG.open("a", encoding="utf-8") as fp:
        fp.write(line + "\n")


def _sanitize_cmd(cmd: list[str]) -> str:
    sanitized: list[str] = []
    for part in cmd:
        if "extraheader=AUTHORIZATION:" in part:
            sanitized.append("http.https://github.com/.extraheader=AUTHORIZATION: basic <redacted>")
        else:
            sanitized.append(part)
    return " ".join(sanitized)


def run(cmd: list[str], check: bool = True, capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    printable = _sanitize_cmd(cmd)
    log(f"$ {printable}")
    result = subprocess.run(
        cmd,
        cwd=str(ROOT),
        check=False,
        text=True,
        capture_output=capture_output,
    )
    if result.stdout:
        with ACTIVITY_LOG.open("a", encoding="utf-8") as fp:
            fp.write(result.stdout)
            if not result.stdout.endswith("\n"):
                fp.write("\n")
    if result.stderr:
        with ERROR_LOG.open("a", encoding="utf-8") as fp:
            fp.write(result.stderr)
            if not result.stderr.endswith("\n"):
                fp.write("\n")
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed ({result.returncode}): {printable}")
    return result


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def load_env() -> dict[str, str]:
    env = dict(os.environ)
    env.update(load_env_file(ROOT / ".env"))
    env.update(load_env_file(DATA_DIR / ".env"))
    return env


def git_repo_initialized() -> bool:
    result = run(["git", "rev-parse", "--is-inside-work-tree"], check=False, capture_output=True)
    return result.returncode == 0 and "true" in (result.stdout or "").strip().lower()


def ensure_git_repo(branch: str) -> None:
    if git_repo_initialized():
        return
    log("Git repo not initialized here. Running git init...")
    run(["git", "init"])
    run(["git", "checkout", "-B", branch])


def detect_repo_slug(env: dict[str, str]) -> str:
    repo_value = env.get("GITHUB_REPO", "").strip()
    owner = env.get("GITHUB_OWNER", "").strip()
    repo_name = env.get("GITHUB_REPO_NAME", "").strip()
    if repo_value and "/" in repo_value:
        return repo_value
    if repo_value and owner:
        return f"{owner}/{repo_value}"
    if repo_value and repo_name:
        return f"{repo_value}/{repo_name}"
    if repo_value and "/" not in repo_value:
        # Backward compatible mode: value is owner only.
        return f"{repo_value}/{ROOT.name}"
    raise RuntimeError("GITHUB_REPO missing. Use owner/repo format in .env.")


def set_remote(repo_slug: str) -> None:
    remote_url = f"https://github.com/{repo_slug}.git"
    remotes = run(["git", "remote"], capture_output=True).stdout.splitlines()
    if "origin" in remotes:
        run(["git", "remote", "set-url", "origin", remote_url])
    else:
        run(["git", "remote", "add", "origin", remote_url])


def bump_versions(skip: bool) -> None:
    if skip:
        return
    run([sys.executable, str(ROOT / "scripts" / "bump_versions.py")])


def commit_changes(message: str) -> None:
    run(["git", "add", "-A"])
    status = run(["git", "status", "--porcelain"], capture_output=True).stdout.strip()
    if not status:
        log("No local changes to commit.")
        return
    run(["git", "commit", "-m", message])


def push_with_token(token: str, branch: str) -> None:
    auth = base64.b64encode(f"x-access-token:{token}".encode("utf-8")).decode("ascii")
    run(
        [
            "git",
            "-c",
            f"http.https://github.com/.extraheader=AUTHORIZATION: basic {auth}",
            "push",
            "-u",
            "origin",
            branch,
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Initialize/bump/commit/push 8bbSmartController using .env token.")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--message", default="chore: update 8bbSmartController")
    parser.add_argument("--skip-bump", action="store_true")
    args = parser.parse_args()

    env = load_env()
    token = env.get("GITHUB_TOKEN", "").strip()
    if not token:
        raise RuntimeError("GITHUB_TOKEN missing in .env or environment.")
    repo_slug = detect_repo_slug(env)

    ensure_git_repo(args.branch)
    run(["git", "checkout", "-B", args.branch])
    set_remote(repo_slug)
    bump_versions(args.skip_bump)
    commit_changes(args.message)
    push_with_token(token, args.branch)
    log(f"Push complete to {repo_slug} on branch {args.branch}")
    log(f"Activity log: {ACTIVITY_LOG}")
    log(f"Error log: {ERROR_LOG}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        log_error(str(exc))
        raise SystemExit(1)
