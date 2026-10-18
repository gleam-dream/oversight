"""Authored loopback instrument; run inside Oversight's Nix shell."""

import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import threading
import tomllib
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
EVIDENCE = ROOT / ".artifacts"
REQUESTS = []


class Instrument(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        target = urlsplit(self.path)
        page = int(parse_qs(target.query)["page"][0])
        REQUESTS.append([target.path, page])
        assert self.headers["Authorization"] == "Bearer FIXTURE-HEADER-MARKER"
        assert self.headers["X-Instrument-Fixture"] == "FIXTURE-CUSTOM-MARKER"
        assert parse_qs(target.query)["fixture_token"] == ["capture"]
        body = {
            "instrument": {"id": "synthetic-spectrometer"},
            "measurements": [
                {
                    "wavelength_nm": 500 if page == 1 else 600,
                    "counts": 42 if page == 1 else 4090,
                }
            ],
            "next": 2 if page == 1 else None,
        }
        if target.path == "/invalid":
            body["measurements"][0]["counts"] = "FIXTURE-BODY-MARKER"
        payload = json.dumps(body, separators=(",", ":")).encode()
        if target.path == "/oversized":
            payload = b" " * 2048 + payload
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Instrument-Fixture", "FIXTURE-RESPONSE-MARKER")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        if target.path == "/truncated":
            self.wfile.write(payload[:30])
        else:
            self.wfile.write(payload)
        self.wfile.flush()
        self.close_connection = True


def command(mode, port, cassette):
    environment = os.environ | {
        "INSTRUMENT_MODE": mode,
        "INSTRUMENT_URL": f"http://127.0.0.1:{port}",
        "INSTRUMENT_CASSETTE": str(cassette),
        "ERL_FLAGS": os.environ.get("ERL_FLAGS", "+S 2:2 +A 2"),
    }
    code_paths = sorted(
        str(path) for path in (ROOT / "build/dev/erlang").glob("*/ebin")
    )
    args = [
        "erl",
        "-pa",
        *code_paths,
        "-noshell",
        "-eval",
        "{ok, _} = application:ensure_all_started(instrument_replay), "
        "instrument_replay:main(), halt().",
    ]
    result = subprocess.run(
        args, cwd=ROOT, env=environment, text=True, capture_output=True, timeout=90
    )
    print(result.stdout, end="")
    print(result.stderr, end="")
    (EVIDENCE / f"{mode}.log").write_text(result.stdout + result.stderr)
    result.check_returncode()


def main():
    EVIDENCE.mkdir(exist_ok=True)
    for command_args in [
        ["gleam", "format", "--check", "src"],
        ["gleam", "build", "--warnings-as-errors"],
    ]:
        subprocess.run(command_args, cwd=ROOT, check=True, timeout=240)
    with tempfile.TemporaryDirectory(prefix="oversight-instrument-replay-") as temp:
        subprocess.run(
            ["erlc", "-Werror", "-o", temp, "src/instrument_replay_env.erl"],
            cwd=ROOT,
            check=True,
            timeout=30,
        )
        cassette = Path(temp) / "capture.json"
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Instrument)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            command("capture", port, cassette)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
        with socket.socket() as probe:
            assert probe.connect_ex(("127.0.0.1", port)) != 0, (
                "fixture remains reachable"
            )
        print("PASS fixture stopped: TCP connection refused before replay")
        before = cassette.read_bytes()
        for marker in [
            b"FIXTURE-HEADER-MARKER",
            b"FIXTURE-CUSTOM-MARKER",
            b"FIXTURE-RESPONSE-MARKER",
            b"FIXTURE-BODY-MARKER",
        ]:
            assert marker not in before, "fixture marker leaked"
        assert b"fixture_token=REDACTED" in before
        assert b"REDACTED" in before
        assert REQUESTS == [
            ["/measurements", 1],
            ["/measurements", 2],
            ["/invalid", 1],
            ["/truncated", 1],
            ["/oversized", 1],
        ]
        command("replay", port, cassette)
        assert cassette.read_bytes() == before, "replay mutated historical evidence"
        assert not list(Path(temp).glob("*.http-gun-*")), "staging directory leaked"
        (EVIDENCE / "capture.json").write_bytes(before)
        receipt = {
            "fixture_stopped_before_replay": True,
            "live_requests": REQUESTS,
            "fixture_markers_absent": True,
            "capture_unchanged_by_replay": True,
            "staging_directories_remaining": 0,
            "capture_sha256": hashlib.sha256(before).hexdigest(),
            "oracle": "authored synthetic fixtures; no external oracle",
        }
        (EVIDENCE / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        locked = {
            package["name"]: package["commit"]
            for package in tomllib.loads((ROOT / "manifest.toml").read_text())["packages"]
            if package.get("source") == "git"
        }
        revisions = {
            "oversight": subprocess.check_output(
                ["git", "-C", str(ROOT.parent.parent), "rev-parse", "HEAD"], text=True
            ).strip(),
            **locked,
        }
        tracked_dirty = {
            "oversight": bool(
                subprocess.check_output(
                    [
                        "git",
                        "-C",
                        str(ROOT.parent.parent),
                        "status",
                        "--porcelain",
                        "--untracked-files=no",
                    ],
                    text=True,
                ).strip()
            )
        }
        runtime = subprocess.check_output(
            [
                "erl",
                "+S",
                "2:2",
                "-noshell",
                "-eval",
                'io:format("~s", [erlang:system_info(system_version)]), halt().',
            ],
            text=True,
        )
        provenance = {
            "revisions": revisions,
            "tracked_dirty": tracked_dirty,
            "gleam": subprocess.check_output(["gleam", "--version"], text=True).strip(),
            "erlang": runtime.strip(),
            "python": platform.python_version(),
            "manifest_sha256": hashlib.sha256(
                (ROOT / "manifest.toml").read_bytes()
            ).hexdigest(),
            "scope": "separate consumer; public imports; native loopback HTTP and offline playback",
        }
        (EVIDENCE / "provenance.json").write_text(
            json.dumps(provenance, indent=2) + "\n"
        )
        print(
            "PASS cassette redaction, exact live request count, immutable replay and staging cleanup"
        )


if __name__ == "__main__":
    main()
