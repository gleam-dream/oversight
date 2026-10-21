"""Compile actual generated Gleam source and exercise independent native consumers."""
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def binary(text):
    return "<<" + ",".join(str(byte) for byte in text.encode("utf-8")) + ">>"


def wire_term(value):
    """Independent test data transport; this does not escape generated Gleam source."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "{bool," + str(value).lower() + "}"
    if isinstance(value, int):
        return "{int," + str(value) + "}"
    if isinstance(value, str):
        return "{text," + binary(value) + "}"
    if isinstance(value, list):
        return "{array,[" + ",".join(wire_term(item) for item in value) + "]}"
    if isinstance(value, dict):
        entries = ("{" + binary(key) + "," + wire_term(item) + "}"
                   for key, item in value.items())
        return "{object,[" + ",".join(entries) + "]}"
    raise TypeError(f"Unsupported fixture value: {type(value)}")


COMMON = """
import generated/document
import lab/blueprint as b
import lab/blueprint_document as loader
import lab/blueprint_runtime as runtime
import lab/value as v

@external(erlang, "generation_fixture_ffi", "schema")
fn expected_schema() -> v.Value

@external(erlang, "generation_fixture_ffi", "name")
fn expected_name() -> String

@external(erlang, "generation_fixture_ffi", "enum_label")
fn enum_label(index: Int) -> String

pub fn main() -> Nil {
  let codec = document.codec()
  let assert Ok(expected) = loader.load(expected_schema())
  let assert Ok(actual) = runtime.from_codec(codec)
  let assert True = runtime.same_schema(expected, actual)
"""

RECORD = """
  let base = [#("name", v.Text("Ada")), #("quantity", v.Int(3))]
  let assert Ok(document.Document("Ada", b.Missing, 3)) =
    b.decode(codec, v.Object(base))
  let assert Ok(document.Document("Ada", b.Present(b.Null), 3)) =
    b.decode(codec, v.Object([#("note", v.Null), ..base]))
  let native = document.Document("Ada", b.Present(b.NonNull("memo")), 3)
  let assert Ok(decoded) =
    b.decode(codec, v.Object([#("note", v.Text("memo")), ..base]))
  let assert True = decoded == native
  let assert Ok(encoded) = b.encode(codec, native)
  let assert Ok(roundtrip) = b.decode(codec, encoded)
  let assert True = roundtrip == native
  let assert Error(_) = b.encode(codec, document.Document("Ada", b.Missing, 11))
  let assert Error(_) = b.decode(codec, v.Object([#("name", v.Text("Ada")), #("quantity", v.Int(0))]))
  let assert Error(_) = b.decode(codec, v.Object([#("quantity", v.Int(3))]))
  let assert Error(_) = b.decode(codec, v.Object([#("extra", v.Bool(True)), ..base]))
  let assert Error(_) = b.decode(codec, v.Object([#("name", v.Int(1)), #("quantity", v.Int(3))]))
"""

EMPTY = """
  let native = document.Document
  let assert Ok(v.Object([])) = b.encode(codec, native)
  let assert Ok(decoded) = b.decode(codec, v.Object([]))
  let assert True = decoded == native
  let assert Error(_) = b.decode(codec, v.Object([#("extra", v.Int(1))]))
"""

PRIMITIVES = """
  let native = document.Document(True, 42, b.NonNull(b.NonNull("deep")))
  let assert Ok(encoded) = b.encode(codec, native)
  let assert Ok(decoded) = b.decode(codec, encoded)
  let assert True = decoded == native
  let assert Ok(document.Document(False, -2, b.Null)) =
    b.decode(codec, v.Object([#("active", v.Bool(False)), #("count", v.Int(-2)), #("deep", v.Null)]))
  let assert Error(_) = b.encode(codec, document.Document(True, 42, b.NonNull(b.Null)))
"""

ESCAPE = """
  let name = expected_name()
  let native = document.Document("payload")
  let assert Ok(v.Object([#(encoded_name, v.Text("payload"))])) = b.encode(codec, native)
  let assert True = encoded_name == name
  let assert Ok(decoded) = b.decode(codec, v.Object([#(name, v.Text("payload"))]))
  let assert True = decoded == native
"""



def enum_body(single=False):
    # Fixed independent constructor contract, exercised against externally supplied labels.
    lines = []
    for index in range(1 if single else 6):
        native = f"document.Document(document.Field0Value{index})" if single else (
            f"document.Document(document.Field0Value{index}, "
            f"b.NonNull(document.Field1Value{index}), b.Present(document.Field2Value{index}))")
        fields = [f'#("only", v.Text(enum_label({index})))'] if single else [
            f'#("{field}", v.Text(enum_label({index})))' for field in ["alpha", "beta", "gamma"]]
        lines += [f"  let native = {native}", f"  let wire = v.Object([{', '.join(fields)}])",
                  "  let assert Ok(decoded) = b.decode(codec, wire)",
                  "  let assert True = decoded == native",
                  "  let assert Ok(encoded) = b.encode(codec, native)",
                  "  let assert True = encoded == wire"]
    if not single:
        lines += [
            '  let assert Ok(document.Document(document.Field0Value0, b.Null, b.Missing)) = b.decode(codec, v.Object([#("alpha", v.Text("")), #("beta", v.Null)]))',
            '  let assert Error(_) = b.decode(codec, v.Object([#("alpha", v.Text("unknown")), #("beta", v.Null)]))',
            '  let assert Error(_) = b.decode(codec, v.Object([#("alpha", v.Int(0)), #("beta", v.Null)]))',
            '  let assert Error(_) = b.decode(codec, v.Object([#("beta", v.Null)]))',
            '  let assert Error(_) = b.decode(codec, v.Object([#("alpha", v.Text("")), #("beta", v.Null), #("gamma", v.Null)]))',
        ]
    return "\n".join(lines)

def run(directory, *args):
    return subprocess.run(["gleam", *args], cwd=directory, text=True, capture_output=True)


def copy_dependencies(directory):
    pending = [Path("generated_probe.gleam")]
    seen = set()
    while pending:
        relative = pending.pop()
        if relative in seen:
            continue
        seen.add(relative)
        target = directory / "src" / relative
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "src" / relative, target)
        text = target.read_text()
        pending.extend(Path(name + ".gleam")
                       for name in re.findall(r"^import ([a-z0-9_/]+)", text, re.M))
        for name in re.findall(r'@external\(erlang,\s*"([^"]+)"', text):
            ffi = ROOT / "src" / (name + ".erl")
            if ffi.exists():
                shutil.copy2(ffi, directory / "src" / ffi.name)


def check_negative(directory, source, fragments):
    target = directory / "src" / "invalid_generated_consumer.gleam"
    target.write_text(source)
    try:
        result = run(directory, "check")
        diagnostic = result.stdout + result.stderr
        errors = re.findall(r"^error:", diagnostic, re.M)
        if (result.returncode == 0 or len(errors) != 1
                or "invalid_generated_consumer.gleam" not in diagnostic
                or not all(fragment in diagnostic for fragment in fragments)):
            raise SystemExit("FAIL: generated native boundary negative\n" + diagnostic)
    finally:
        target.unlink()


def main():
    result = run(ROOT, "run", "-m", "codegen_corpus")
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    cases = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    if {case["label"] for case in cases} != {"record", "empty", "primitives", "escape", "enum_record", "enum_single"}:
        raise SystemExit("FAIL: missing generated-source fixture family")
    bodies = {"record": RECORD, "empty": EMPTY, "primitives": PRIMITIVES, "escape": ESCAPE, "enum_record": enum_body(), "enum_single": enum_body(True)}
    for case in cases:
        with tempfile.TemporaryDirectory(prefix="oversight-generated-") as temp:
            directory = Path(temp)
            (directory / "src" / "generated").mkdir(parents=True)
            shutil.copy2(ROOT / "gleam.toml", directory / "gleam.toml")
            (directory / "src" / "generated" / "document.gleam").write_text(case["source"])
            (directory / "src" / "generated_probe.gleam").write_text(
                COMMON + bodies[case["label"]] + "\n  Nil\n}\n"
            )
            (directory / "src" / "generation_fixture_ffi.erl").write_text(
                "-module(generation_fixture_ffi).\n-export([schema/0,name/0,enum_label/1]).\n"
                + "schema() -> " + wire_term(case["schema"]) + ".\n"
                + "name() -> " + binary(case["name"]) + ".\n"
                + "enum_label(Index) -> lists:nth(Index + 1, ["
                + ",".join(binary(label) for label in ([""] if case["label"] == "enum_single" else sorted(["case", "", "é漢字😀", "line\nbreak", 'quote"label', "back\\slash"]))) + "]).\n"
            )
            copy_dependencies(directory)
            result = run(directory, "run", "-m", "generated_probe")
            if result.returncode:
                raise SystemExit(
                    f"FAIL: generated-source consumer {case['label']}\n"
                    + result.stdout + result.stderr
                )
            if case["label"] == "record":
                check_negative(directory, """
import generated/document
import lab/blueprint_runtime as runtime
pub fn invalid(value: runtime.ValidatedValue) -> document.Document { value }
""", ["Type mismatch", "ValidatedValue", "Document"])
                check_negative(directory, """
import generated/document
import lab/blueprint
import lab/blueprint_runtime as runtime
pub fn invalid(value: runtime.RuntimeContract) -> blueprint.Codec(document.Document) { value }
""", ["Type mismatch", "RuntimeContract", "Codec"])
            if case["label"] == "enum_record":
                check_negative(directory, """
import generated/document
pub fn invalid(value: String) -> document.Field0Enum { value }
""", ["Type mismatch", "String", "Field0Enum"])
                check_negative(directory, """
import generated/document
pub fn invalid(value: document.Field1Enum) -> document.Field0Enum { value }
""", ["Type mismatch", "Field1Enum", "Field0Enum"])
    print(f"PASS: {len(cases)} generated modules compile and run native consumers; 4 native-boundary negatives pass")


if __name__ == "__main__":
    main()
