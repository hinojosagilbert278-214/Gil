#!/usr/bin/env bash
# Applies migrations to a fresh database and runs ledger invariant + concurrency tests.
# Requires: DATABASE_URL pointing at a superuser-capable empty Postgres server (no db name needed).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DATABASE_URL:?set DATABASE_URL, e.g. ******localhost:5432/postgres}"
DB="xtc_test_$$"
ADMIN="$DATABASE_URL"
TEST_URL="${ADMIN%/*}/$DB"
psql "$ADMIN" -qc "CREATE DATABASE $DB"
trap 'psql "$ADMIN" -qc "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null' EXIT
for f in migrations/*.sql; do psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$f" >/dev/null; done
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f tests/invariants.sql >/dev/null

# Concurrency 1: 20 parallel gifts (distinct tx) from a wallet funded for only 10.
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -c "
  INSERT INTO accounts(username,email) VALUES ('csender','cs@x'),('ccreator','cc@x'),('dsender','ds@x');
  SELECT ledger_credit_purchase(gen_random_uuid(), (SELECT id FROM accounts WHERE username='csender'), 1000);
  SELECT ledger_credit_purchase(gen_random_uuid(), (SELECT id FROM accounts WHERE username='dsender'), 1000);" >/dev/null
OUT=$(mktemp -d)
for i in $(seq 1 20); do
  ( if psql "$TEST_URL" -q -c "SELECT wallet_process_live_gift(gen_random_uuid(),
      (SELECT id FROM accounts WHERE username='csender'),
      (SELECT id FROM accounts WHERE username='ccreator'), 100)" >/dev/null 2>"$OUT/err.$i"; then
      touch "$OUT/ok.$i"; else touch "$OUT/fail.$i"; fi ) &
done
wait
OK=$(ls "$OUT" | grep -c '^ok\.' || true); FAIL=$(ls "$OUT" | grep -c '^fail\.' || true)
echo "distinct-tx race: $OK succeeded, $FAIL failed"
[ "$OK" -eq 10 ] && [ "$FAIL" -eq 10 ] || { echo "FAIL: expected 10 successes / 10 failures"; exit 1; }
# every failure must be an insufficient-funds check violation
for f in "$OUT"/fail.*; do n=${f##*fail.}; grep -q "violates check constraint" "$OUT/err.$n" || { echo "FAIL: unexpected error: $(cat "$OUT/err.$n")"; exit 1; }; done

# Concurrency 2: 20 parallel retries of the SAME tx uuid must apply exactly once.
TX=$(psql "$TEST_URL" -Atqc "SELECT gen_random_uuid()")
for i in $(seq 1 20); do
  psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -c "SELECT wallet_process_live_gift('$TX',
    (SELECT id FROM accounts WHERE username='dsender'),
    (SELECT id FROM accounts WHERE username='ccreator'), 100)" >/dev/null 2>"$OUT/dup.$i" &
done
wait
[ -z "$(cat "$OUT"/dup.* )" ] || { echo "FAIL: duplicate retries errored: $(cat "$OUT"/dup.*)"; exit 1; }
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -v tx="$TX" -f tests/concurrency_check.sql >/dev/null
# Concurrency 3: same tx uuid, 20 DIFFERENT amounts -> exactly one wins, the rest are rejected.
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -c "
  INSERT INTO accounts(username,email) VALUES ('esender','es@x');
  SELECT ledger_credit_purchase(gen_random_uuid(), (SELECT id FROM accounts WHERE username='esender'), 10000);" >/dev/null
TX2=$(psql "$TEST_URL" -Atqc "SELECT gen_random_uuid()")
for i in $(seq 1 20); do
  ( if psql "$TEST_URL" -q -c "SELECT wallet_process_live_gift('$TX2',
      (SELECT id FROM accounts WHERE username='esender'),
      (SELECT id FROM accounts WHERE username='ccreator'), $((i * 10)))" >/dev/null 2>"$OUT/cf.$i"; then
      touch "$OUT/cfok.$i"; else touch "$OUT/cffail.$i"; fi ) &
done
wait
OK=$(ls "$OUT" | grep -c '^cfok\.' || true); FAIL=$(ls "$OUT" | grep -c '^cffail\.' || true)
echo "conflicting-payload race: $OK succeeded, $FAIL rejected"
[ "$OK" -eq 1 ] && [ "$FAIL" -eq 19 ] || { echo "FAIL: expected 1 success / 19 rejections"; exit 1; }
for f in "$OUT"/cffail.*; do n=${f##*cffail.}; grep -q "reused with a different request" "$OUT/cf.$n" || { echo "FAIL: unexpected error: $(cat "$OUT/cf.$n")"; exit 1; }; done
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -v tx="$TX2" -f tests/conflict_check.sql >/dev/null
echo "ALL LEDGER TESTS PASSED"
