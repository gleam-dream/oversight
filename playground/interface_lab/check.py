#!/usr/bin/env python3
"""THROWAWAY: Check positive composition and reject invalid interface consumers.

Run from the repository root: nix develop --command python3 playground/interface_lab/check.py
Each negative fixture has a sibling .expect containing required diagnostic text,
one fragment per line. Each runs in an isolated copy of the positive sources.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parent


def check(directory):
    return subprocess.run(
        ["gleam", "check"], cwd=directory, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )


def report_failure(output):
    errors = re.findall(r"^error:.*?(?=^error:|^warning:|\Z)", output, re.M | re.S)
    print("\n".join(errors) if errors else output)


def main():
    version = subprocess.run(["gleam", "--version"], capture_output=True, text=True, check=True)
    print(version.stdout.strip())
    positive = check(ROOT)
    if positive.returncode:
        report_failure(positive.stdout)
        raise SystemExit("FAIL: positive consumers do not compile")
    print("PASS: positive interface consumers compile")
    for consumer in sorted((ROOT / "src" / "consumers").glob("*.gleam")):
        with tempfile.TemporaryDirectory(prefix="oversight-consumer-") as temp:
            directory = Path(temp)
            shutil.copy2(ROOT / "gleam.toml", directory / "gleam.toml")
            pending = [consumer.relative_to(ROOT / "src")]
            seen = set()
            while pending:
                relative = pending.pop()
                if relative in seen:
                    continue
                seen.add(relative)
                source = ROOT / "src" / relative
                target = directory / "src" / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
                imports = re.findall(r"^import ([a-z0-9_/]+)", source.read_text(), re.M)
                pending.extend(Path(module + ".gleam") for module in imports)
            result = check(directory)
            if result.returncode:
                report_failure(result.stdout)
                raise SystemExit(f"FAIL: isolated consumer {consumer.stem}")
            print(f"PASS: {consumer.stem} compiles with only its {len(seen)} source modules")
    fixtures = sorted((ROOT / "negative").glob("*.gleam"))
    if not fixtures:
        raise SystemExit("FAIL: no negative fixtures")
    for fixture in fixtures:
        expected = fixture.with_suffix(".expect")
        if not expected.exists():
            raise SystemExit(f"FAIL: missing expected diagnostic for {fixture.name}")
        fragments = [line for line in expected.read_text().splitlines()
                     if line.strip() and not line.startswith("#")]
        if not fragments:
            raise SystemExit(f"FAIL: empty expected diagnostic for {fixture.name}")
        with tempfile.TemporaryDirectory(prefix="oversight-interface-") as temp:
            directory = Path(temp)
            shutil.copy2(ROOT / "gleam.toml", directory / "gleam.toml")
            shutil.copytree(ROOT / "src", directory / "src")
            shutil.copy2(fixture, directory / "src" / "invalid_consumer.gleam")
            result = check(directory)
            diagnostics = re.findall(r"^error:.*?(?=^error:|\Z)", result.stdout, re.M | re.S)
            diagnostic = diagnostics[0] if len(diagnostics) == 1 else ""
            if result.returncode == 0 or any(fragment not in diagnostic for fragment in fragments):
                report_failure(result.stdout)
                raise SystemExit(f"FAIL: {fixture.name} did not fail with its expected diagnostic")
            if "invalid_consumer.gleam" not in diagnostic:
                report_failure(result.stdout)
                raise SystemExit(f"FAIL: {fixture.name} failed outside the intended consumer")
            print(f"PASS: {fixture.stem} rejected as expected")
    print(f"Checked positive consumers and {len(fixtures)} negative fixtures.")
    probes = subprocess.run(
        ["gleam", "run", "-m", "stress_checks"], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if probes.returncode:
        report_failure(probes.stdout)
        raise SystemExit("FAIL: pure interface probes")
    print("PASS: interface probe groups")
    import schema_check
    schema_check.main()
    print("No scheduler, storage, protocol transport, or unfinished runtime boundary is executed.")


if __name__ == "__main__":
    main()
