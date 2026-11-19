#!/usr/bin/env bash
# Record the compiler's real output for each broken variant in broken/<name>/:
# copy this package to a temporary directory, overlay the variant's modules,
# build, and keep the error with paths made relative. Run inside nix develop
# after changing a snippet or the Gleam version.
set -euo pipefail
cd "$(dirname "$0")"
# Format the variants first: the pre-commit hook would, and the recorded
# line numbers must match the files as committed.
gleam format broken
mkdir -p output
for variant in broken/*/; do
  name=$(basename "$variant")
  work=$(cd "$(mktemp -d)" && pwd -P)
  cp -R gleam.toml manifest.toml src "$work/"
  cp -R "$variant"/. "$work/src/"
  if (cd "$work" && gleam build >/dev/null 2>"$work/err"); then
    echo "broken/$name compiled; it must not" >&2
    exit 1
  fi
  sed -e 's/\x1b\[[0-9;]*m//g' -e "s#[^ ]*$work/##g" -e "s#[^ ]*${work#/private}/##g" "$work/err" |
    sed -n '/^error:/,$p' >"output/$name.txt"
  rm -rf "$work"
  echo "captured output/$name.txt"
done
