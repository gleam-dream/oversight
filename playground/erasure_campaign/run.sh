#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .artifacts
exec > >(tee .artifacts/latest.log) 2>&1
tmp="$(mktemp -d /tmp/erasure-campaign.XXXXXX)"
fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  gleam --version
  erl -noshell -eval 'io:format("OTP ~s ERTS ~s~n", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().'
  postgres --version
  python3 --version
  for package in oversight saga grind http_gun sinal; do
    repo="../../../$package"
    revision="$(git -C "$repo" rev-parse HEAD)"
    changes="$(git -C "$repo" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
    printf '%s %s tracked-change-lines=%s\n' "$package" "$revision" "$changes"
  done
  sha256sum gleam.toml manifest.toml ../../flake.lock
} > .artifacts/provenance.txt
gleam format --check src test
gleam build --warnings-as-errors
python3 src/fixture.py "$tmp/port" &
fixture_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$tmp/port" ]] && break
  kill -0 "$fixture_pid"
  sleep 0.02
done
fixture_port="$(cat "$tmp/port")"
export ERASURE_FIXTURE_URL="http://127.0.0.1:$fixture_port"
../../apps/scripts/with-postgres.sh gleam test
