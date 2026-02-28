from __future__ import annotations

import base64
import hashlib
import hmac
import os
from pathlib import Path

from cryptography.fernet import Fernet
from cryptography.fernet import InvalidToken

from .storage import DATA_DIR

KEY_FILE = DATA_DIR / "secrets.key"


def _load_or_create_key() -> bytes:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if KEY_FILE.exists():
        return KEY_FILE.read_bytes()
    key = Fernet.generate_key()
    KEY_FILE.write_bytes(key)
    return key


FERNET = Fernet(_load_or_create_key())


def encrypt_secret(value: str) -> str:
    if not value:
        return ""
    return FERNET.encrypt(value.encode("utf-8")).decode("utf-8")


def decrypt_secret(value: str) -> str:
    if not value:
        return ""
    try:
        return FERNET.decrypt(value.encode("utf-8")).decode("utf-8")
    except InvalidToken:
        # Backward compatibility for plain-text values saved before encryption.
        return value


def hash_passcode(passcode: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.scrypt(passcode.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=64)
    return base64.b64encode(salt + digest).decode("utf-8")


def verify_passcode(passcode: str, encoded: str | None) -> bool:
    if not encoded:
        return False
    raw = base64.b64decode(encoded.encode("utf-8"))
    salt = raw[:16]
    digest = raw[16:]
    candidate = hashlib.scrypt(passcode.encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=64)
    return hmac.compare_digest(candidate, digest)
