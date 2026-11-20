#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
# Build with every warning as an error, except one. JSON Blueprint 2.1.1's
# typed generator ends each enum encoder with a catch-all arm that an
# exhaustive enum makes unreachable; until a release emits guarded arms, an
# `Unreachable pattern` warning in a module under `src/**/generated/` is
# accepted and any other warning fails. Restore `gleam build
# --warnings-as-errors` with that release:
# issues/codec-copy-cost/issues/02-build-generated-codecs-with-warnings-as-errors.md
strict_build() {
  local log
  log=$(mktemp)
  gleam build 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  local other
  other=$(awk '
    /^warning: / { title = $0; getline location
      if (!(title == "warning: Unreachable pattern" && location ~ /\/src\/.*\/generated\//)) print title }
  ' "$log")
  rm -f "$log"
  [ "$status" -eq 0 ] || return "$status"
  if [ -n "$other" ]; then
    echo "warnings outside the accepted generated-enum case:" >&2
    echo "$other" >&2
    return 1
  fi
}
if [ "$#" -eq 0 ]; then
  set -- apps/*/gleam.toml
  for manifest in "$@"; do bash "$0" "$(basename "$(dirname "$manifest")")"; done
  exit
fi
for name in "$@"; do
  (
    cd "apps/$name"
    strict_build
    output=$(mktemp -d)
    trap 'rm -rf "$output"' EXIT
    export ERL_LIBS="$PWD/build/dev/erlang:$PWD/build/packages"
    find src test -name '*.erl' -exec erlc -Werror -o "$output" {} +
    export OVERSIGHT_PG_LOG_DIR="$root/.artifacts/ci/$name/postgres"
    case "$name" in
    email_portal | support_desk | tool_hub | session_replay | moderation_desk) gleam test ;;
    *) "$root/apps/scripts/with-postgres.sh" gleam test ;;
    esac
  )
done
