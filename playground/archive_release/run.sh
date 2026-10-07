#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
gleam format --check src test
gleam build --warnings-as-errors
mkdir -p build/ffi_check
erlc -Werror -o build/ffi_check test/archive_release_test_ffi.erl
../../apps/scripts/with-postgres.sh gleam test
