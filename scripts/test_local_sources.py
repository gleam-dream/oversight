"""Behavioral checks for isolated coordinated-source captures."""

from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

from local_sources import snapshot


class LocalSourcesTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="oversight-capture-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.workspace = self.base / "workspace"
        self.output = self.base / "capture"
        self.names = ("oversight", "retrace", "json_blueprint")
        for name in self.names:
            directory = self.workspace / name
            directory.mkdir(parents=True)
            subprocess.run(["git", "init", "--quiet", str(directory)], check=True)
            self.write(name + "/gleam.toml", f'name = "{name}"\nversion = "0.1.0"\n')
        for relative, name in (
            ("packages/retrace_frontend", "retrace_frontend"),
            ("packages/retrace_server", "retrace_server"),
            ("support/collector", "retrace_collector"),
        ):
            self.write(
                f"retrace/{relative}/gleam.toml",
                f'name = "{name}"\nversion = "0.1.0"\n'
                '[dependencies]\nretrace = ">= 0.1.0 and < 0.2.0"\n',
            )

    def write(self, relative, contents):
        path = self.workspace / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def capture(self):
        snapshot(self.workspace, self.output, self.names)

    def dependencies(self, relative):
        return tomllib.loads((self.output / relative).read_text())["dependencies"]

    def test_retrace_children_use_captured_packages_for_hex_git_and_path_sources(self):
        self.write(
            "oversight/apps/replay/gleam.toml",
            'name = "replay"\nversion = "0.1.0"\n[dependencies]\n'
            'retrace_frontend = ">= 0.1.0 and < 0.2.0"\n'
            'retrace_server = { git = "https://github.com/gleam-dream/retrace.git", '
            'ref = "selected", path = "packages/retrace_server" }\n'
            'retrace_collector = { path = "../../../retrace/support/collector" }\n',
        )
        self.write(
            "retrace/support/collector/gleam.toml",
            'name = "retrace_collector"\nversion = "0.1.0"\n[dependencies]\n'
            'retrace = ">= 0.1.0 and < 0.2.0"\n'
            'retrace_server = ">= 0.1.0 and < 0.2.0"\n',
        )
        before = (self.workspace / "oversight/apps/replay/gleam.toml").read_bytes()
        self.capture()
        application = self.dependencies("oversight/apps/replay/gleam.toml")
        for relative, name in (
            ("packages/retrace_frontend", "retrace_frontend"),
            ("packages/retrace_server", "retrace_server"),
            ("support/collector", "retrace_collector"),
        ):
            self.assertEqual(application[name], {"path": str(self.output / "retrace" / relative)})
        collector = self.dependencies("retrace/support/collector/gleam.toml")
        self.assertEqual(collector["retrace"], {"path": str(self.output / "retrace")})
        self.assertEqual(
            collector["retrace_server"],
            {"path": str(self.output / "retrace/packages/retrace_server")},
        )
        self.assertEqual((self.workspace / "oversight/apps/replay/gleam.toml").read_bytes(), before)

    def test_exact_historical_oracle_versions_and_locks_are_preserved(self):
        for version in ("1.7.1", "1.1.0"):
            directory = "oversight/oracles/blueprint_" + version.replace(".", "_")
            self.write(
                directory + "/gleam.toml",
                'name = "historical_probe"\nversion = "0.1.0"\n[dependencies]\n'
                f'json_blueprint = "== {version}"\n',
            )
            self.write(directory + "/manifest.toml", 'packages = []\n')
        self.capture()
        for version in ("1.7.1", "1.1.0"):
            directory = "oversight/oracles/blueprint_" + version.replace(".", "_")
            self.assertEqual(self.dependencies(directory + "/gleam.toml")["json_blueprint"], "== " + version)
            self.assertEqual((self.output / directory / "manifest.toml").read_bytes(), b'packages = []\n')

    def test_unrelated_git_source_is_not_replaced(self):
        declaration = (
            'name = "foreign_probe"\nversion = "0.1.0"\n[dependencies]\n'
            'retrace_server = { git = "https://example.test/other/retrace.git", '
            'ref = "selected", path = "packages/retrace_server" }\n'
        )
        self.write("oversight/apps/foreign/gleam.toml", declaration)
        self.capture()
        self.assertEqual((self.output / "oversight/apps/foreign/gleam.toml").read_text(), declaration)


if __name__ == "__main__":
    unittest.main()
