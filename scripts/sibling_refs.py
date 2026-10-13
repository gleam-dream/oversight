"""Validate the complete sibling pin set before checkout."""

import os
import re
from pathlib import Path

from ci import SIBLINGS


def parse_pins(text: str) -> dict[str, str]:
    pins = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([a-z_]+)=([0-9a-f]{40})", line)
        if not match or match[1] in pins:
            raise ValueError("Sibling revisions must be unique package=40hexSHA lines")
        pins[match[1]] = match[2]
    if set(pins) != set(SIBLINGS):
        raise ValueError("The sibling revision set is incomplete or contains unknown packages")
    return pins


def main() -> None:
    pins = parse_pins((Path(__file__).resolve().parents[1] / "sibling-revisions.txt").read_text())
    current = os.environ.get("CURRENT", "false")
    if current not in ("true", "false"):
        raise ValueError("CURRENT must be true or false")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        for name, revision in pins.items():
            if current == "true":
                revision = "main" if name in {"json_blueprint", "retrace"} else "master"
            output.write(f"{name}={revision}\n")


if __name__ == "__main__":
    main()
