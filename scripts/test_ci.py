"""Failure controls for the CI runner, without application services."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ci
import sibling_refs


class GateTests(unittest.TestCase):
    def test_retrace_checkout_uses_pin_or_main_for_compatibility(self):
        pins = (ci.ROOT / "sibling-revisions.txt").read_text()
        self.assertIn("retrace", sibling_refs.parse_pins(pins))
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "outputs"
            for current in ("false", "true"):
                output.write_text("")
                with patch.dict("os.environ", {
                    "CURRENT": current, "GITHUB_OUTPUT": str(output),
                }):
                    sibling_refs.main()
                refs = dict(line.split("=", 1) for line in output.read_text().splitlines())
                expected = "main" if current == "true" else sibling_refs.parse_pins(pins)["retrace"]
                self.assertEqual(refs["retrace"], expected)

    def test_compatibility_refuses_to_rewrite_a_local_checkout(self):
        with patch.dict("os.environ", {"GITHUB_ACTIONS": "false"}):
            with self.assertRaises(ValueError):
                ci.current_sources()

    def test_current_sources_preserve_adapter_paths_and_frozen_inputs(self):
        source = (
            '[dependencies]\n'
            'saga_postgres = { git = "https://github.com/gleam-dream/saga.git", '
            f'ref = "{"a" * 40}", path = "integrations/saga_postgres" }}\n'
            'json_blueprint = "== 1.1.0"\n'
            'other = { git = "https://github.com/example/other.git", ref = "v1" }\n'
        )
        changed = ci.replace_git_refs(source, {"saga": "b" * 40})
        self.assertIn('path = "integrations/saga_postgres"', changed)
        self.assertIn('ref = "' + "b" * 40 + '"', changed)
        self.assertIn('json_blueprint = "== 1.1.0"', changed)
        self.assertIn('ref = "v1"', changed)
        with self.assertRaises(ValueError):
            ci.replace_git_refs(source.replace("a" * 40, "master"), {"saga": "b" * 40})


    def test_sibling_checkout_selects_pins_and_default_branches(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("ci.py", "sibling_refs.py"):
                shutil.copyfile(Path(__file__).parent / name, scripts / name)
            pins = {name: "a" * 40 for name in ci.SIBLINGS}
            pins["correio"] = "b" * 40
            (root / "sibling-revisions.txt").write_text(
                "".join(f"{name}={revision}\n" for name, revision in pins.items())
            )
            for current in ("false", "true"):
                with self.subTest(current=current):
                    output = root / f"{current}.txt"
                    subprocess.run(
                        [sys.executable, "-B", str(scripts / "sibling_refs.py")],
                        env={**os.environ, "CURRENT": current, "GITHUB_OUTPUT": str(output)},
                        check=True,
                    )
                    refs = dict(line.split("=", 1) for line in output.read_text().splitlines())
                    if current == "false":
                        self.assertEqual(refs, pins)
                    else:
                        self.assertEqual(refs["correio"], "main")
                        self.assertEqual(refs["json_blueprint"], "main")
                        self.assertEqual(refs["warden"], "master")
                        self.assertEqual(set(refs), set(pins))

    def test_sibling_pins_reject_missing_duplicate_and_untrusted_refs(self):
        pins = "".join(f"{name}={'a' * 40}\n" for name in ci.SIBLINGS)
        self.assertEqual(set(sibling_refs.parse_pins(pins)), set(ci.SIBLINGS))
        for invalid in ("", pins + pins, pins.replace("a" * 40, "master", 1), pins + f"other={'a' * 40}\n"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                sibling_refs.parse_pins(invalid)

    def test_required_jobs_must_all_succeed(self):
        expected = ("quality", "applications", "experiments", "design")
        results = {name: {"result": "success"} for name in expected}
        ci.require_success(results, expected)
        for state in ("failure", "cancelled", "skipped", "pending", None):
            with self.subTest(state=state), self.assertRaises(ValueError):
                ci.require_success({**results, "applications": {"result": state}}, expected)
        with self.assertRaises(ValueError):
            ci.require_success({}, expected)
        with self.assertRaises(ValueError):
            ci.require_success({}, ())
        with self.assertRaises(ValueError):
            ci.require_success({**results, "unexpected": {"result": "success"}}, expected)

    def test_failed_command_retains_diagnostics(self):
        with tempfile.TemporaryDirectory() as folder:
            evidence = Path(folder) / "evidence"
            with self.assertRaises(subprocess.CalledProcessError):
                ci.run(
                    [sys.executable, "-c", "print('failure control', flush=True); raise SystemExit(7)"],
                    cwd=Path(folder),
                    evidence=evidence,
                )
            self.assertIn("failure control", next(evidence.glob("*.log")).read_text())

    def test_native_warning_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "src"
            source.mkdir()
            native = source / "warning_control.erl"
            native.write_text(
                "-module(warning_control).\n-export([value/0]).\nvalue() -> Unused = 1, 2.\n"
            )
            with self.assertRaises(subprocess.CalledProcessError):
                ci.compile_erlang(root, root / "evidence")
            native.write_text("-module(warning_control).\n-export([value/0]).\nvalue() -> 2.\n")
            ci.compile_erlang(root, root / "evidence")


if __name__ == "__main__":
    unittest.main()
