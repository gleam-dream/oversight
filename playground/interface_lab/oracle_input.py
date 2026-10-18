"""Fetch a pinned upstream oracle input into the ignored artifacts directory."""

import hashlib
import urllib.request
from pathlib import Path

CACHE = Path(__file__).resolve().parents[2] / ".artifacts" / "oracle-inputs"


def fetch(name: str, url: str, sha256: str) -> bytes:
    """Return the bytes of `url`, verified against `sha256` and cached under `name`."""
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / name
    if target.is_file():
        cached = target.read_bytes()
        if hashlib.sha256(cached).hexdigest() == sha256:
            return cached
    with urllib.request.urlopen(url, timeout=60) as response:
        raw = response.read()
    actual = hashlib.sha256(raw).hexdigest()
    if actual != sha256:
        raise SystemExit(
            f"FAIL: oracle input {name} from {url}: expected sha256 {sha256}, got {actual}"
        )
    target.write_bytes(raw)
    return raw
