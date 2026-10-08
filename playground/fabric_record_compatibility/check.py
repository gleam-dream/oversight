#!/usr/bin/env python3
"""Write a history record publicly, then require the pinned old reader to refuse it."""

import argparse
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import tomllib


PROJECT = Path(__file__).resolve().parent
READER_REVISION = "c92e97ca3357c15dd26a2fcb59a77bedcffda539"


def git(repository: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(repository), *arguments], text=True
    ).strip()


def snapshot(repository: Path, revision: str, destination: Path) -> None:
    # Only package source, package manifests and license; never local settings,
    # credentials, build directories or another checkout's uncommitted files.
    available = git(repository, "ls-tree", "--name-only", revision).splitlines()
    paths = [
        name
        for name in ("src", "priv", "gleam.toml", "manifest.toml", "LICENSE")
        if name in available
    ]
    archive = subprocess.check_output(
        ["git", "-C", str(repository), "archive", revision, *paths]
    )
    destination.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(destination, filter="data")
    print(f"Pinned {repository.name}: {revision}", flush=True)


def consumer(workspace: Path, name: str, fabric: Path) -> None:
    package = workspace / name
    package_name = "new_writer" if name == "new" else "old_reader"
    shutil.copytree(PROJECT / name / "src", package / "src")
    (package / "gleam.toml").write_text(
        f'name = "{package_name}"\n'
        'version = "0.0.0"\ntarget = "erlang"\n[dependencies]\n'
        f'fabric = {{ path = {json.dumps(str(fabric))} }}\n'
        'gleam_stdlib = ">= 0.70.0 and < 2.0.0"\n'
        'gleam_erlang = ">= 1.0.0 and < 2.0.0"\n'
        'gleam_time = ">= 1.11.0 and < 2.0.0"\n'
    )
    subprocess.run(["gleam", "run"], cwd=package, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("writer", type=Path, help="Fabric checkout with history input")
    writer = parser.parse_args().writer.resolve()
    print(f"Writer checkout: {writer}", flush=True)
    print(f"Writer HEAD: {git(writer, 'rev-parse', 'HEAD')}", flush=True)
    print(git(writer, "status", "--short", "--", "src", "gleam.toml", "manifest.toml"), flush=True)
    manifest = tomllib.loads(git(writer, "show", f"{READER_REVISION}:gleam.toml"))
    pins = dict(
        line.split("=", 1)
        for line in git(writer, "show", f"{READER_REVISION}:sibling-revisions.txt").splitlines()
        if line and not line.startswith("#")
    )
    with tempfile.TemporaryDirectory(prefix="fabric-record-compat-") as temporary:
        workspace = Path(temporary)
        reader = workspace / "reader_sources" / "fabric"
        snapshot(writer, READER_REVISION, reader)
        for name, dependency in manifest["dependencies"].items():
            if isinstance(dependency, dict) and "path" in dependency:
                sibling = (writer / dependency["path"]).resolve()
                snapshot(sibling, pins[name], reader.parent / name)
        consumer(workspace, "new", writer)
        consumer(workspace, "old", reader)


if __name__ == "__main__":
    main()
