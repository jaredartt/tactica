#!/usr/bin/env bash
# Runs the game rules against a throwaway local Postgres.
#
# This does NOT touch your Supabase project. It spins up a temporary cluster,
# fakes the parts of Supabase the migration depends on (the auth schema, the
# anon/authenticated roles, the realtime publication), applies the real
# migration, then plays a whole match through the real RPCs and asserts every
# rule — turn order, move range, the 30s clock, spectator limits, and the RLS
# policies that stop a client from writing the board directly.
#
# Requires a local postgres install (macOS: `brew install postgresql@16`).
#
#   ./supabase/tests/run.sh
#
set -euo pipefail
cd "$(dirname "$0")/../.."

PGBIN="$(pg_config --bindir 2>/dev/null || echo /usr/lib/postgresql/16/bin)"
DATA="$(mktemp -d)/data"
SOCK="$(mktemp -d)"
export PGHOST="$SOCK" PGPORT=5455 PGUSER=postgres

cleanup() { "$PGBIN/pg_ctl" -D "$DATA" stop -m immediate >/dev/null 2>&1 || true; }
trap cleanup EXIT

"$PGBIN/initdb" -D "$DATA" -U postgres --auth=trust >/dev/null
"$PGBIN/pg_ctl" -D "$DATA" -o "-k $SOCK -p 5455 -c listen_addresses=" -l "$DATA/log" start >/dev/null
sleep 1

psql -q -v ON_ERROR_STOP=1 -o /dev/null -c "create extension if not exists pgcrypto;"
psql -q -v ON_ERROR_STOP=1 -o /dev/null -f supabase/tests/00_supabase_stub.sql 2>/dev/null
HELPERS=supabase/tests/_helpers.sql
for m in supabase/migrations/*.sql; do
  psql -q -v ON_ERROR_STOP=1 -o /dev/null -f "$m" 2>/dev/null
done

# helpers go in after the migrations, because they lean on the real tables
psql -q -v ON_ERROR_STOP=1 -o /dev/null -f "$HELPERS" 2>/dev/null

for t in supabase/tests/0[1-9]*.sql; do
  echo "--- $(basename "$t")"
  psql -q -v ON_ERROR_STOP=1 -o /dev/null -f "$t" 2>&1 \
    | sed 's/^psql:[^ ]* //' | grep -E 'PASS|FAIL|ERROR|---'
done
