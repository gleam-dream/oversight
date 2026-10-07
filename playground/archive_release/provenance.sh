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
for package in oversight fabric relay warden json_blueprint llm_wire http_gun sinal; do
  path="../../../$package"
  revision="$(git -C "$path" rev-parse HEAD)"
  if git -C "$path" diff --quiet HEAD --; then tracked=clean; else tracked=dirty; fi
  untracked="$(git -C "$path" ls-files --others --exclude-standard | wc -l | tr -d ' ')"
  printf '%s %s tracked=%s untracked_files=%s\n' "$package" "$revision" "$tracked" "$untracked"
done
printf 'fabric_postgres: nested in fabric at the same revision.\n'
printf 'Dependency resolution SHA-256: '
sha256sum manifest.toml
printf 'Consumer Gleam source SHA-256:\n'
sha256sum src/archive_release/*.gleam test/*.gleam test/*.erl
