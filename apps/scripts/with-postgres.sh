#!/usr/bin/env bash
# Run a command against a disposable PostgreSQL 16 cluster.
#
#   apps/scripts/with-postgres.sh gleam test
#
# The command sees DATABASE_URL, PGHOST, PGPORT, PGUSER and PGDATABASE. The
# cluster lives in a temporary directory, listens on 127.0.0.1 at a random
# free port, trusts local connections, and is removed on exit.
set -euo pipefail

root="$(mktemp -d "${TMPDIR:-/tmp}/apps-postgres.XXXXXX")"
cluster="$root/data"
started=0
cleanup() {
  if [[ "$started" == 1 ]]; then
    pg_ctl -D "$cluster" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$root"
}
trap cleanup EXIT

for _ in $(seq 1 20); do
  port=$((20000 + RANDOM % 20000))
  pg_isready -h 127.0.0.1 -p "$port" >/dev/null 2>&1 || break
done

initdb -D "$cluster" --username=app --auth-local=trust --auth-host=trust >/dev/null
pg_ctl -D "$cluster" -o "-h 127.0.0.1 -p $port -k $root" -l "$root/postgres.log" start >/dev/null
started=1
createdb -h 127.0.0.1 -p "$port" -U app app

export PGHOST=127.0.0.1 PGPORT="$port" PGUSER=app PGDATABASE=app
export DATABASE_URL="postgres://app@127.0.0.1:$port/app"
"$@"
