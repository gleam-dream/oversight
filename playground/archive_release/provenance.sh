#!/usr/bin/env bash
# Print a read-only receipt. Run in the same Nix shell as run.sh.
set -euo pipefail
cd "$(dirname "$0")"
date -u '+Captured: %Y-%m-%dT%H:%M:%SZ'
gleam --version
printf 'Erlang/OTP '
erl -noshell -eval 'io:format("~s (~s)~n", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().'
rebar3 --version
postgres --version
uname -sm
revision="$(git -C ../.. rev-parse HEAD)"
if git -C ../.. diff --quiet HEAD --; then tracked=clean; else tracked=dirty; fi
printf 'oversight %s tracked=%s\n' "$revision" "$tracked"
grep -oE 'name = "[a-z_]+"[^}]*source = "git", repo = "[^"]+", commit = "[0-9a-f]{40}"' manifest.toml |
  sed -E 's/name = "([a-z_]+)".*repo = "([^"]+)", commit = "([0-9a-f]{40})"/locked \1 \2 \3/'
printf 'Dependency resolution SHA-256: '
sha256sum manifest.toml
printf 'Consumer Gleam source SHA-256:\n'
sha256sum src/archive_release/*.gleam test/*.gleam test/*.erl
