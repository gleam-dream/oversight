#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
if [ "$#" -eq 0 ]; then
  set -- apps/*/gleam.toml
  for manifest in "$@"; do bash "$0" "$(basename "$(dirname "$manifest")")"; done
  exit
fi
for name in "$@"; do
  (
    cd "apps/$name"
    gleam build --warnings-as-errors
    output=$(mktemp -d)
    trap 'rm -rf "$output"' EXIT
    export ERL_LIBS="$PWD/build/dev/erlang:$PWD/build/packages"
    find src test -name '*.erl' -exec erlc -Werror -o "$output" {} +
    export OVERSIGHT_PG_LOG_DIR="$root/.artifacts/ci/$name/postgres"
    case "$name" in
    email_portal | support_desk | tool_hub | session_replay) gleam test ;;
    *) "$root/apps/scripts/with-postgres.sh" gleam test ;;
    esac
  )
done
