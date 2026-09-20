#!/usr/bin/env python3
"""Run the pinned upstream compatibility experiment and its independent oracles."""

from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib

from jsonschema import Draft7Validator


PROJECT = Path(__file__).resolve().parents[1]
HISTORICAL = PROJECT / "upstream_1_1"


def check_pin(project: Path, version: str, checksum: str) -> None:
    manifest = tomllib.loads((project / "manifest.toml").read_text())
    packages = [p for p in manifest["packages"] if p["name"] == "json_blueprint"]
    assert len(packages) == 1, "missing or duplicate upstream package pin"
    package = packages[0]
    assert package["version"] == version, "upstream version changed"
    assert package["source"] == "hex", "upstream source changed"
    assert package["outer_checksum"].lower() == checksum, "upstream checksum changed"


def run(command: list[str], cwd: Path, *, capture: bool = False) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    output = completed.stdout or "" if capture else ""
    if completed.returncode != 0:
        if capture:
            print(output, end="")
        raise SystemExit(
            f"command failed ({completed.returncode}): {' '.join(command)}"
        )
    return output


def check_draft7(output: str) -> None:
    schemas: dict[str, dict] = {}
    for line in output.splitlines():
        if line.startswith("SCHEMA_EMPTY:"):
            schemas["empty"] = json.loads(line.removeprefix("SCHEMA_EMPTY:"))
        if line.startswith("SCHEMA_TUPLE:"):
            schemas["tuple"] = json.loads(line.removeprefix("SCHEMA_TUPLE:"))

    assert set(schemas) == {"empty", "tuple"}, "Gleam run omitted schema output"
    empty_schema = schemas["empty"]
    tuple_schema = schemas["tuple"]
    assert empty_schema["$schema"] == "http://json-schema.org/draft-07/schema#"
    assert tuple_schema["$schema"] == "http://json-schema.org/draft-07/schema#"
    Draft7Validator.check_schema(empty_schema)
    Draft7Validator.check_schema(tuple_schema)

    empty = Draft7Validator(empty_schema)
    assert empty.is_valid({})
    assert not empty.is_valid({"extra": True})
    assert not empty.is_valid(5)
    assert not empty.is_valid(None)

    tuple_validator = Draft7Validator(tuple_schema)
    assert tuple_validator.is_valid([1, "one"])
    # Draft 7 ignores the later-dialect prefixItems keyword, so the schema
    # accepts wrong element types that json_blueprint's tuple decoder rejects.
    assert tuple_validator.is_valid(["one", 1])
    assert not tuple_validator.is_valid([1])
    print("Draft 7 schema oracle: empty-object and tuple-prefix mismatch confirmed")


def negative_project(source: str, filename: str, expected: tuple[str, ...]) -> None:
    with tempfile.TemporaryDirectory(prefix="blueprint-compat-negative-") as raw:
        project = Path(raw)
        shutil.copy2(PROJECT / "gleam.toml", project / "gleam.toml")
        shutil.copy2(PROJECT / "manifest.toml", project / "manifest.toml")
        shutil.copytree(PROJECT / "src", project / "src")
        (project / "src" / filename).write_text(source)

        run(["gleam", "deps", "download"], project)
        output = subprocess.run(
            ["gleam", "check"],
            cwd=project,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        assert output.returncode != 0, f"negative fixture unexpectedly compiled: {filename}"
        diagnostics = re.findall(r"^error:.*?(?=^error:|\Z)", output.stdout, re.M | re.S)
        assert len(diagnostics) == 1, output.stdout
        diagnostic = diagnostics[0]
        assert filename in diagnostic, output.stdout
        for fragment in expected:
            assert fragment in diagnostic, output.stdout


def check_compiler_negatives() -> None:
    negative_project(
        """import json/blueprint as legacy
import lab/blueprint

pub fn decoder_is_not_codec(
  decoder: legacy.Decoder(String),
) -> blueprint.Codec(String) {
  decoder
}
""",
        "negative_decoder_codec.gleam",
        ("Type mismatch", "legacy.Decoder(String)", "blueprint.Codec(String)"),
    )
    negative_project(
        """import adapter
import json/blueprint as legacy
import lab/blueprint
import lab/value

pub fn wrong_native_encoder(
  decoder: legacy.Decoder(String),
) -> blueprint.Codec(String) {
  adapter.adapt(decoder, fn(_item: Int) {
    Ok(value.Text("wrong native type"))
  })
}
""",
        "negative_encoder_native_type.gleam",
        ("Type mismatch", "String", "Int"),
    )
    print("compiler negatives: decoder/codec and wrong native encoder rejected")


def main() -> None:
    check_pin(PROJECT, "1.7.1", "6260f1e9a609a5ec3fbe638745744a3bbbd5fcec37b0792ac7ea631efa4d20d7")
    check_pin(HISTORICAL, "1.1.0", "879833acfaf7ef9fac1e90ef78e41e5d3cbb0fa718d63105efc597fe520930bf")
    run(["python3", "scripts/snapshot_lab.py"], PROJECT)
    run(["gleam", "format", "--check", "src"], PROJECT)
    run(["gleam", "deps", "download"], PROJECT)
    run(["gleam", "check"], PROJECT)
    output = run(["gleam", "run", "-m", "main"], PROJECT, capture=True)
    print(output, end="")
    assert "all json_blueprint adapter probes passed" in output
    check_draft7(output)

    run(["gleam", "format", "--check", "src"], HISTORICAL)
    run(["gleam", "deps", "download"], HISTORICAL)
    run(["gleam", "check"], HISTORICAL)
    historical_output = run(
        ["gleam", "run", "-m", "main"], HISTORICAL, capture=True
    )
    print(historical_output, end="")
    assert "json_blueprint 1.1.0 direct decoder probes passed" in historical_output

    check_compiler_negatives()
    print("all compatibility checks passed")


if __name__ == "__main__":
    main()
