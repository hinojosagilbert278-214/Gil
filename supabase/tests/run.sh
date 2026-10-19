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

# Concurrency: 20 parallel gifts from one sender with funds for only 10.
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -c "
  INSERT INTO accounts(username,email) VALUES ('csender','cs@x'),('ccreator','cc@x');
  SELECT ledger_credit_purchase(gen_random_uuid(), (SELECT id FROM accounts WHERE username='csender'), 1000);" >/dev/null
for i in $(seq 1 20); do
  psql "$TEST_URL" -q -c "SELECT wallet_process_live_gift(gen_random_uuid(),
    (SELECT id FROM accounts WHERE username='csender'),
    (SELECT id FROM accounts WHERE username='ccreator'), 100)" >/dev/null 2>&1 &
done
wait
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f tests/concurrency_check.sql >/dev/null
echo "ALL LEDGER TESTS PASSED"
