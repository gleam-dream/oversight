#!/usr/bin/env python3
"""Copy current authored sources for an explicitly unpublished consumer experiment."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import tomllib
from pathlib import Path

SIBLINGS = (
    "sinal", "json_blueprint", "http_gun", "saga", "grind",
    "llm_wire", "relay", "hellhound", "fabric", "correio", "retrace",
)


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True)


def permitted(path: Path) -> bool:
    # Inspect names before reading bytes. Secrets, local settings and caches never
    # enter the copy, even if accidentally tracked.
    return not any(
        part.startswith(".") or part in {"build", "node_modules", "__pycache__"}
        or "credential" in part.lower() or part.lower().startswith("settings.local")
        for part in path.parts
    )


def snapshot(root: Path, target: Path, names: tuple[str, ...]) -> None:
    target.mkdir(exist_ok=False)
    sources = {}
    for name in names:
        source = root / name
        tracked = set(git(source, "ls-files", "-z").split("\0")) - {""}
        untracked = set(git(source, "ls-files", "--others", "--exclude-standard", "-z").split("\0")) - {""}
        authored = {path for path in untracked if Path(path).suffix in {".gleam", ".erl", ".toml", ".typ", ".md", ".py", ".sh"}}
        hashes = {}
        for entry in sorted(tracked | authored):
            relative = Path(entry)
            path = source / relative
            if not permitted(relative) or path.is_symlink() or not path.is_file():
                continue
            destination = target / name / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            content = path.read_bytes()
            hashes[entry] = hashlib.sha256(content).hexdigest()
            destination.write_bytes(content)
            shutil.copymode(path, destination)
        revision = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "--verify", "HEAD"],
            text=True, capture_output=True, check=False,
        )
        sources[name] = {
            "revision": revision.stdout.strip() if revision.returncode == 0 else None,
            "dirty": bool(git(source, "status", "--porcelain")),
            "files": hashes,
        }
    packages = {name: target / name for name in names if name != "oversight"}
    repositories = {name: name for name in packages}
    for owner, folder, name in (
        ("saga", "integrations", "saga_postgres"),
        ("fabric", "integrations", "fabric_postgres"),
        ("hellhound", "integrations", "hellhound_postgres"),
        ("correio", "adapters", "correio_mailbox"),
        ("correio", "adapters", "correio_postmark"),
        ("correio", "adapters", "correio_postgres"),
    ):
        if owner in names and (target / owner / folder / name / "gleam.toml").is_file():
            packages[name] = target / owner / folder / name
            repositories[name] = owner
    changed = []
    for manifest in target.rglob("gleam.toml"):
        original = manifest.read_text()
        contents = original
        config = tomllib.loads(contents)
        for section in ("dependencies", "dev-dependencies"):
            for name, dependency in config.get(section, {}).items():
                # Historical exact Hex versions and unrelated sources stay frozen.
                if name not in packages:
                    continue
                if isinstance(dependency, str):
                    if dependency.lstrip().startswith("=="):
                        continue
                    dependency = {}
                repository = dependency.get("git", "")
                owner = "lostbean" if repositories[name] == "json_blueprint" else "gleam-dream"
                expected = f"https://github.com/{owner}/{repositories[name]}.git"
                if repository and repository != expected:
                    continue
                if dependency and not repository and "path" not in dependency:
                    continue
                contents = re.sub(
                    rf'(?m)^{re.escape(name)}\s*=\s*(?:\{{[^\n]*\}}|"[^"\n]*")',
                    lambda _: f'{name} = {{ path = "{packages[name]}" }}',
                    contents,
                )
        if contents != original:
            manifest.write_text(contents)
            changed.append(str(manifest.relative_to(target)))
            manifest.with_name("manifest.toml").unlink(missing_ok=True)
    (target / "sources.json").write_text(json.dumps(sources, indent=2) + "\n")
    (target / "resolution-overrides.json").write_text(json.dumps(changed, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new directory; existing directories are refused")
    args = parser.parse_args()
    target = args.output
    if target is None:
        target = Path(tempfile.mkdtemp(prefix="oversight-local-")) / "sources"
    target = target.resolve()
    root = Path(__file__).resolve().parents[2]
    if target.is_relative_to(root):
        parser.error("output must be outside the source workspace")
    snapshot(root, target, ("oversight", *SIBLINGS))
    print(target)
    print("Unpublished local-source experiment; original manifests were not changed.")


if __name__ == "__main__":
    main()
