"""Compare emitted Blueprint schemas with a separately implemented validator."""
import json
import subprocess
from pathlib import Path

from jsonschema import Draft202012Validator


def main():
    root = Path(__file__).resolve().parent
    result = subprocess.run(
        ["gleam", "run", "-m", "schema_corpus"], cwd=root,
        text=True, capture_output=True,
    )
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    cases = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    if not cases:
        raise SystemExit("FAIL: empty schema agreement corpus")
    outcomes = set()
    for case in cases:
        Draft202012Validator.check_schema(case["schema"])
        accepted = Draft202012Validator(case["schema"]).is_valid(case["instance"])
        if accepted != case["accepted"]:
            raise SystemExit(f"FAIL: schema disagreement: {case['label']}: {case}")
        outcomes.add(accepted)
    if outcomes != {True, False}:
        raise SystemExit("FAIL: corpus must include accepted and rejected instances")
    print(f"PASS: {len(cases)} schema/decoder cases agree with Draft202012Validator")


if __name__ == "__main__":
    main()
