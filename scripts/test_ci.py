"""Failure controls for the CI runner, without application services."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ci


class GateTests(unittest.TestCase):
    def test_locked_sources_list_each_git_commit_once_per_repository(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for name, commit in (("one", "a" * 40), ("two", "a" * 40), ("three", "b" * 40)):
                package = root / name
                package.mkdir()
                (package / "manifest.toml").write_text(
                    "packages = [\n"
                    '  { name = "sinal", version = "0.1.0", build_tools = ["gleam"], '
                    'requirements = [], source = "git", '
                    f'repo = "https://github.com/gleam-dream/sinal.git", commit = "{commit}" }},\n'
                    '  { name = "gleam_stdlib", version = "1.0.5", build_tools = ["gleam"], '
                    'requirements = [], source = "hex", outer_checksum = "00" },\n'
                    "]\n"
                )
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            with patch.object(ci, "ROOT", root):
                self.assertEqual(
                    ci.locked_sources(),
                    {"https://github.com/gleam-dream/sinal.git": ["a" * 40, "b" * 40]},
                )

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
