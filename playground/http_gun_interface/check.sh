#!/bin/sh
set -eu
probe_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
probe_tmp=$(mktemp -d)
trap 'rm -rf "$probe_tmp"' EXIT HUP INT TERM
cp -R "$probe_root/library" "$probe_tmp/library"
cp -R "$probe_root/consumer" "$probe_tmp/consumer"
cd "$probe_tmp/consumer"
gleam check
for fixture in forge_client string_body; do
  cp "$probe_root/negative/$fixture.gleam" src/negative.gleam
  if gleam check > "$probe_tmp/$fixture.log" 2>&1; then
    echo "Expected compiler rejection: $fixture" >&2
    exit 1
  fi
  case "$fixture" in
    forge_client) expected='Unknown module value' ;;
    string_body) expected='Type mismatch' ;;
  esac
  if ! grep -q "$expected" "$probe_tmp/$fixture.log"; then
    cat "$probe_tmp/$fixture.log" >&2
    exit 1
  fi
  rm src/negative.gleam
done
echo "Separate consumer compiled; opaque-client and body-type negatives rejected."
echo "Compiler evidence only: no HTTP, lifecycle, disk, or recording implementation ran."
