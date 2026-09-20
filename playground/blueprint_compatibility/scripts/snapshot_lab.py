#!/usr/bin/env python3
"""Copy the minimal existing lab boundary needed by this separate project."""

from pathlib import Path
import shutil


PROJECT = Path(__file__).resolve().parents[1]
REPOSITORY = PROJECT.parents[1]
LAB = REPOSITORY / "playground" / "interface_lab" / "src"
SOURCES = (
    "lab/value.gleam",
    "lab/blueprint.gleam",
    "lab/blueprint_runtime.gleam",
    "lab/blueprint_document.gleam",
    "lab/relay.gleam",
    "blueprint_runtime_ffi.erl",
)


def main() -> None:
    for relative in SOURCES:
        source = LAB / relative
        destination = PROJECT / "src" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


if __name__ == "__main__":
    main()
