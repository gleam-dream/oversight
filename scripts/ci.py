#!/usr/bin/env python3
"""Run the ecosystem's retained consumer checks in the repository Nix shell."""

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / ".artifacts" / "ci"
APPLICATIONS = (
    "checkout", "extractor", "financial_recovery", "research_agent", "secure_mcp",
    "sso_portal", "support_desk", "tool_hub", "webhooks",
)
DATABASE_APPS = frozenset(APPLICATIONS) - {"support_desk", "tool_hub"}
SIBLINGS = (
    "sinal", "json_blueprint", "http_gun", "saga", "grind",
    "llm_wire", "relay", "warden", "fabric",
)


def require_success(results: object, expected: tuple[str, ...]) -> None:
    if not expected or not isinstance(results, dict) or set(results) != set(expected):
        raise ValueError("The required CI job results are missing or unexpected")
    failed = [
        name for name, result in results.items()
        if not isinstance(result, dict) or result.get("result") != "success"
    ]
    if failed:
        raise ValueError("Required CI jobs did not succeed: " + ", ".join(failed))


def run(
    command: list[str], *, cwd: Path = ROOT, evidence: Path = EVIDENCE,
    env: dict[str, str] | None = None, timeout: int = 900,
) -> None:
    evidence.mkdir(parents=True, exist_ok=True)
    log = evidence / f"{time.time_ns()}-{Path(command[0]).name}.log"
    started = time.monotonic()
    print(f"{cwd}: {' '.join(command)}", flush=True)
    with log.open("w") as output:
        process = subprocess.Popen(
            command, cwd=cwd, env=env, stdout=output,
            stderr=subprocess.STDOUT, start_new_session=True,
        )
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
    with (evidence / "commands.jsonl").open("a") as receipt:
        receipt.write(json.dumps({
            "command": command, "cwd": str(cwd), "exit": code,
            "seconds": time.monotonic() - started, "log": log.name,
        }) + "\n")
    if code:
        print(log.read_text()[-24000:], file=sys.stderr)
        raise subprocess.CalledProcessError(code, command)
    print(f"Passed ({time.monotonic() - started:.1f}s); {log}", flush=True)


def compile_erlang(package: Path, evidence: Path = EVIDENCE) -> None:
    sources = sorted(
        path for folder in ("src", "test")
        for path in (package / folder).rglob("*.erl")
    )
    if not sources:
        return
    env = dict(os.environ)
    env["ERL_LIBS"] = os.pathsep.join(
        str(package / folder) for folder in ("build/dev/erlang", "build/packages")
    )
    with tempfile.TemporaryDirectory(prefix="oversight-erlc-") as output:
        run(
            ["erlc", "-Werror", "-o", output, *map(str, sources)],
            cwd=package, evidence=evidence, env=env,
        )


def inventory() -> None:
    found = {path.parent.name for path in (ROOT / "apps").glob("*/gleam.toml")}
    if found != set(APPLICATIONS):
        raise ValueError(f"Application gate inventory differs: {found ^ set(APPLICATIONS)}")


def provenance() -> None:
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    revisions = {}
    for name in ("oversight", *SIBLINGS):
        path = ROOT if name == "oversight" else ROOT.parent / name
        if not path.is_dir():
            raise ValueError(f"Missing sibling checkout: {path}")
        revisions[name] = {
            "revision": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=path, text=True,
            ).strip(),
            "dirty": bool(subprocess.check_output(
                ["git", "status", "--porcelain", "--untracked-files=no"], cwd=path, text=True,
            )),
        }
    (EVIDENCE / "sources.json").write_text(json.dumps(revisions, indent=2) + "\n")
    (EVIDENCE / "flake-lock.sha256").write_text(
        hashlib.sha256((ROOT / "flake.lock").read_bytes()).hexdigest() + "\n"
    )
    run(["gleam", "--version"])
    run(["erl", "-noshell", "-eval", 'io:format("~s~n", [erlang:system_info(system_version)]), halt().'])


def quality() -> None:
    inventory()
    run(["nix", "flake", "check", "--no-update-lock-file"])
    run(["actionlint", "-color"])
    run(["ruff", "check", "scripts", "playground"])
    run(["shellcheck", "apps/scripts/with-postgres.sh", "playground/http_gun_interface/check.sh"])
    run([sys.executable, "-B", "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py"])


def application(name: str) -> None:
    inventory()
    if name not in APPLICATIONS:
        raise ValueError(f"Unknown application: {name}")
    package = ROOT / "apps" / name
    run(["gleam", "format", "--check", "src", "test"], cwd=package)
    run(["gleam", "build", "--warnings-as-errors"], cwd=package)
    compile_erlang(package)
    command = ["gleam", "test"]
    if name in DATABASE_APPS:
        command = [str(ROOT / "apps/scripts/with-postgres.sh"), *command]
    env = dict(os.environ)
    env["OVERSIGHT_PG_LOG_DIR"] = str(EVIDENCE / name / "postgres")
    run(command, cwd=package, env=env)


def experiments() -> None:
    run([sys.executable, "-B", "playground/interface_lab/check.py"])
    run([sys.executable, "-B", "playground/blueprint_compatibility/scripts/check.py"])
    run(["sh", "playground/http_gun_interface/check.sh"])
    pilot = ROOT / "playground/ecosystem_pilot"
    run(["gleam", "build", "--warnings-as-errors"], cwd=pilot)
    compile_erlang(pilot)
    run(["gleam", "test"], cwd=pilot)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=("quality", "application", "experiments", "full", "result", "inventory"))
    parser.add_argument("names", nargs="*")
    args = parser.parse_args()
    if args.profile == "result":
        require_success(json.loads(os.environ.get("NEEDS_JSON", "null")), tuple(args.names))
        return
    if args.profile == "inventory":
        if args.names:
            parser.error("inventory accepts no extra arguments")
        inventory()
        print(json.dumps(APPLICATIONS))
        return
    if args.profile == "application":
        if len(args.names) != 1 or args.names[0] not in APPLICATIONS:
            parser.error("application requires one registered application name")
    elif args.names:
        parser.error("this profile accepts no extra arguments")
    if args.profile in ("application", "experiments", "full"):
        provenance()
    if args.profile in ("quality", "full"):
        quality()
    if args.profile == "application":
        application(args.names[0])
    if args.profile == "full":
        for name in APPLICATIONS:
            application(name)
    if args.profile in ("experiments", "full"):
        experiments()
    if args.profile == "full":
        run(["nix", "run", ".#design-gate-check", "--", "docs/design", "."])


if __name__ == "__main__":
    main()
