#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
python3 -B playground/interface_lab/check.py
python3 -B playground/blueprint_compatibility/scripts/check.py
sh playground/http_gun_interface/check.sh
for name in ecosystem_pilot relay_admission; do
  (
    cd "playground/$name"
    gleam build --warnings-as-errors
    output=$(mktemp -d)
    trap 'rm -rf "$output"' EXIT
    export ERL_LIBS="$PWD/build/dev/erlang:$PWD/build/packages"
    find src test -name '*.erl' -exec erlc -Werror -o "$output" {} +
    if [ "$name" = relay_admission ]; then export ERL_FLAGS='+S 4:4'; fi
    gleam test
  )
done
for name in archive_release instrument_replay erasure_campaign; do
  (
    cd "playground/$name"
    export OVERSIGHT_PG_LOG_DIR="$root/.artifacts/ci/$name/postgres"
    if [ "$name" = instrument_replay ]; then python3 -B run.py; else bash run.sh; fi
  )
done
