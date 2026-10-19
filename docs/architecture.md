# Trust Blue ledger

- All amounts are `BIGINT` micro-units.
- Double-entry: `journal_entries` + `journal_lines` (signed amounts); a deferred constraint trigger requires each entry to sum to zero. Journal tables are append-only.
- `ledger_accounts` hold balances (user wallets, family vaults, TREASURY, EXTERNAL). Only EXTERNAL may be negative; the global sum of balances is always 0.
- Idempotency: `transaction_uuid` is unique; replays return the original entry and do not repeat side effects or outbox events.
- Concurrency: `post_journal` locks accounts in id order (`FOR UPDATE`), so concurrent gifts cannot overdraw or deadlock.
- Live gift split: 70% creator side / 30% treasury; family vault (default 5%) and leader (0–10%) cuts come from the creator's 70%.
- RLS: family members see only their family's membership; users see their own wallets. `my_family_ids()` is `SECURITY DEFINER` to avoid policy recursion. `app.user_id` stands in for Supabase `auth.uid()`.
- Invites: HMAC-SHA256 signature over family|target|expiry, secret from the `app.invite_secret` server setting, constant-time compare.

## Security baseline
CI uses `contents: read` only; no secrets in the repo; the anti-cheat, web, Android and WHIP components are not yet implemented.
