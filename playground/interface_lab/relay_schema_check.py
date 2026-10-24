"""Validate actual Relay output against the pinned upstream MCP schema."""

import copy
import json
from pathlib import Path
import subprocess

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent
REQUIRED_DEFINITIONS = {
    "DiscoverResultResponse",
    "ListToolsResultResponse",
    "CallToolResultResponse",
    "UnsupportedProtocolVersionError",
}


def main():
    schema_path = subprocess.check_output(
        ["nix", "run", "--no-update-lock-file", f"{ROOT.parents[1]}#oracle-mcp-schema"],
        text=True,
    ).strip()
    schema = json.loads(Path(schema_path).read_bytes())
    Draft202012Validator.check_schema(schema)
    result = subprocess.run(
        ["gleam", "run", "-m", "relay_protocol_corpus"],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    cases = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    if not cases:
        raise SystemExit("FAIL: empty Relay wire corpus")
    labels = set()
    definitions = set()
    tool_results = set()
    mutations = 0
    for case in cases:
        label, definition, instance = (
            case["label"], case["definition"], case["instance"]
        )
        if label in labels or definition not in schema["$defs"]:
            raise SystemExit(f"FAIL: invalid Relay corpus identity: {label}")
        labels.add(label)
        definitions.add(definition)
        validator = Draft202012Validator({
            "$schema": schema["$schema"],
            "$defs": schema["$defs"],
            "$ref": f"#/$defs/{definition}",
        })
        errors = list(validator.iter_errors(instance))
        if errors:
            raise SystemExit(f"FAIL: MCP schema disagreement: {label}: {errors[0]}")
        malformed = copy.deepcopy(instance)
        del malformed["jsonrpc"]
        if validator.is_valid(malformed):
            raise SystemExit(f"FAIL: missing JSON-RPC version accepted: {label}")
        mutations += 1
        if "result" in instance:
            if instance["result"]["resultType"] != "complete":
                raise SystemExit(f"FAIL: unexpected modern result kind: {label}")
            malformed = copy.deepcopy(instance)
            del malformed["result"]["resultType"]
            if validator.is_valid(malformed):
                raise SystemExit(f"FAIL: missing result type accepted: {label}")
            mutations += 1
        if definition in {"DiscoverResultResponse", "ListToolsResultResponse"}:
            response = instance["result"]
            if response["cacheScope"] != "private" or response["ttlMs"] != 0:
                raise SystemExit(f"FAIL: unestablished cache policy: {label}")
            for member in ("cacheScope", "ttlMs"):
                malformed = copy.deepcopy(instance)
                del malformed["result"][member]
                if validator.is_valid(malformed):
                    raise SystemExit(f"FAIL: missing {member} accepted: {label}")
                mutations += 1
        if definition == "CallToolResultResponse":
            tool_results.add(instance["result"].get("isError", False))
        if definition == "UnsupportedProtocolVersionError":
            malformed = copy.deepcopy(instance)
            del malformed["error"]["data"]["supported"]
            if validator.is_valid(malformed):
                raise SystemExit("FAIL: missing supported versions accepted")
            mutations += 1
    if not REQUIRED_DEFINITIONS.issubset(definitions):
        raise SystemExit("FAIL: Relay corpus omits a required method or version error")
    if tool_results != {True, False}:
        raise SystemExit("FAIL: Relay corpus must contain tool success and tool error")
    print(
        f"PASS: {len(cases)} Relay outputs match the pinned MCP schema; "
        f"{mutations} malformed mutations are rejected"
    )


if __name__ == "__main__":
    main()
