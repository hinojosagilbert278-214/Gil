# Trust Blue ledger

- All amounts are `BIGINT` micro-units.
- Double-entry: `journal_entries` + `journal_lines` (signed amounts); a deferred constraint trigger requires each entry to sum to zero. Journal tables are append-only.
- `ledger_accounts` hold balances (user wallets, family vaults, TREASURY, EXTERNAL). Only EXTERNAL may be negative; the global sum of balances is always 0.
- Idempotency: `transaction_uuid` is unique; replays return the original entry and do not repeat side effects or outbox events.
- Concurrency: `post_journal` locks accounts in id order (`FOR UPDATE`), so concurrent gifts cannot overdraw or deadlock.
- Live gift split: 70% creator side / 30% treasury; family vault (default 5%) and leader (0–10%) cuts come from the creator's 70%.
- RLS: family members see only their family's membership; users see their own wallets. `my_family_ids()` is `SECURITY DEFINER` to avoid policy recursion. Identity comes from the verified JWT subject (`request.jwt.claim.sub`, i.e. `auth.uid()`), mapped via `accounts.auth_user_id`; unknown subjects see nothing.
- Invites: HMAC-SHA256 signature over family|target|expiry, secret from the `app.invite_secret` server setting, constant-time compare.

## Security baseline
CI uses `contents: read` only; no secrets in the repo; the anti-cheat, web, Android and WHIP components are not yet implemented.

## Hardening
- Ledger functions are `SECURITY DEFINER`, with `EXECUTE` revoked from `PUBLIC` and granted only to `ledger_service` (the trusted backend role). Clients never call them directly.
- Each journal entry stores a SHA-256 request fingerprint. Reusing a `transaction_uuid` with different parameters or type raises `unique_violation`.
- `transactional_outbox.idempotency_key` is unique and inserts use `ON CONFLICT DO NOTHING`.

## Backend role setup (per environment, not in migrations)
`ledger_service` is a `NOLOGIN` permission group with no members in the migrations. Each deployment:

1. Creates a dedicated login role for the trusted server only, e.g. `CREATE ROLE ledger_backend LOGIN PASSWORD '<from secret store>'`.
2. Runs `GRANT ledger_service TO ledger_backend;`.
3. Never grants `ledger_service` to `anon`, `authenticated`, or any client-assumable role. Keep credentials out of the repository.
4. Verifies membership with `supabase/checks/ledger_service_members.sql`, passing the allowed roles:

       psql "$DATABASE_URL" -v allowed="ledger_backend" -f supabase/checks/ledger_service_members.sql

The check exits non-zero if `ledger_service` has any member outside the allowed list.
