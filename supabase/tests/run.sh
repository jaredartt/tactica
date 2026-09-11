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

# _helpers.sql pins the coin flip and the parry/crit dice with `alter database
# t`, so the tests have to run in a database actually called t. Without this
# they ran in the default one, that statement failed, and -- because every psql
# below used to redirect stderr to /dev/null -- the run died with no message at
# all.
psql -q -d postgres -v ON_ERROR_STOP=1 -o /dev/null -c "create database t;"
export PGDATABASE=t

psql -q -v ON_ERROR_STOP=1 -o /dev/null -c "create extension if not exists pgcrypto;"
psql -q -v ON_ERROR_STOP=1 -o /dev/null -f supabase/tests/00_supabase_stub.sql \
  2>&1 | grep -Ev 'wal_level|logical' || true
HELPERS=supabase/tests/_helpers.sql

# Errors are shown, not swallowed. A migration that fails to apply makes every
# assertion after it meaningless, so it has to be loud.
for m in supabase/migrations/*.sql; do
  if ! psql -q -v ON_ERROR_STOP=1 -o /dev/null -f "$m" 2>/tmp/cn_mig_err; then
    echo "MIGRATION FAILED: $m"; sed 's/^psql:[^ ]* //' /tmp/cn_mig_err; exit 1
  fi
done

# helpers go in after the migrations, because they lean on the real tables
if ! psql -q -v ON_ERROR_STOP=1 -o /dev/null -f "$HELPERS" 2>/tmp/cn_help_err; then
  echo "HELPERS FAILED"; sed 's/^psql:[^ ]* //' /tmp/cn_help_err; exit 1
fi

# Numbered files in order, however many there are. The old glob was 0[1-9]*,
# which quietly stopped at 09 -- 10_board.sql would have been skipped without a
# word, and a skipped test file looks exactly like a passing one.
fail=0
for t in $(ls supabase/tests/[0-9][0-9]_*.sql | grep -v '/00_' | sort); do
  echo "--- $(basename "$t")"
  # `|| true` is load-bearing, and its absence was a silent-failure bug of
  # exactly the kind this file has had before. ON_ERROR_STOP makes psql exit
  # non-zero on the first failed assertion; with `set -e` and `pipefail` above,
  # a failing command substitution ended the whole script THERE -- before the
  # echo below ever ran. So a broken test file printed its name, nothing else,
  # and no verdict. It looked like a file that had no assertions in it.
  out="$(psql -q -v ON_ERROR_STOP=1 -o /dev/null -f "$t" 2>&1 | sed 's/^psql:[^ ]* //')" || true
  echo "$out" | grep -E 'PASS|FAIL|ERROR' || true
  echo "$out" | grep -qE 'FAIL|ERROR' && fail=1
done

echo
if [ "$fail" = 0 ]
  then echo "all green"
  else echo "SOMETHING FAILED"; exit 1
fi
