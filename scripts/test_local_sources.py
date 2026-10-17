"""The local-source experiment never alters a source checkout."""

import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import local_sources


class LocalSourcesTests(unittest.TestCase):
    def test_snapshot_includes_new_source_and_normalizes_transitive_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ("oversight", "http_gun", "sinal"):
                repo = root / name
                repo.mkdir()
                subprocess.run(["git", "init", "-q", str(repo)], check=True)
                (repo / "src").mkdir()
                (repo / "src/main.gleam").write_text("pub fn main() { Nil }\n")
                (repo / "gleam.toml").write_text('[dependencies]\n')
            manifest = root / "oversight/gleam.toml"
            manifest.write_text(
                '[dependencies]\n'
                'http_gun = { git = "https://github.com/gleam-dream/http_gun.git", ref = "' + 'a' * 40 + '" }\n'
                'sinal = { path = "../sinal" }\n'
                'json_blueprint = "== 1.1.0"\n'
                'external = { git = "https://example.com/external", ref = "v1" }\n'
            )
            (root / "http_gun/gleam.toml").write_text(
                '[dependencies]\nsinal = { git = "https://github.com/gleam-dream/sinal.git", ref = "' + 'b' * 40 + '" }\n'
            )
            for name in ("oversight", "http_gun", "sinal"):
                subprocess.run(["git", "-C", str(root / name), "add", "."], check=True)
            # New intended source is included; unrelated settings/secrets are not read.
            (root / "sinal/src/new.gleam").write_text("pub fn new() { Nil }\n")
            (root / "sinal/.env.local").write_text("DO_NOT_COPY\n")
            (root / "sinal/settings.local.json").write_text("DO_NOT_COPY\n")
            original = manifest.read_bytes()
            target = root / "snapshot"
            local_sources.snapshot(root, target, ("oversight", "http_gun", "sinal"))
            self.assertEqual(manifest.read_bytes(), original)
            self.assertTrue((target / "sinal/src/new.gleam").is_file())
            self.assertFalse((target / "sinal/.env.local").exists())
            self.assertFalse((target / "sinal/settings.local.json").exists())
            source = (target / "oversight/gleam.toml").read_text()
            self.assertIn(str(target / "http_gun"), source)
            self.assertIn('json_blueprint = "== 1.1.0"', source)
            self.assertIn('ref = "v1"', source)
            self.assertIn(str(target / "sinal"), (target / "http_gun/gleam.toml").read_text())
            receipt = json.loads((target / "sources.json").read_text())
            self.assertEqual(receipt["oversight"]["files"]["gleam.toml"], hashlib.sha256(original).hexdigest())
            with self.assertRaises(FileExistsError):
                local_sources.snapshot(root, target, ("oversight",))

    def test_same_name_from_another_repository_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            repo = root / "sinal"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            original = '[dependencies]\nsinal = { git = "https://github.com/gleam-dream/other.git", ref = "' + 'a' * 40 + '" }\n'
            (repo / "gleam.toml").write_text(original)
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            target = root / "snapshot"
            local_sources.snapshot(root, target, ("sinal",))
            self.assertEqual((target / "sinal/gleam.toml").read_text(), original)


if __name__ == "__main__":
    unittest.main()
