# Gil — XTC LIVE + XTC PLAY Super-App

Status: foundation only. Implemented: the Trust Blue ledger (PostgreSQL) with tests and CI.
`apps/web`, `packages/shared` and `android` are placeholders.

## Layout
- `supabase/migrations` — schema, ledger functions, RLS/invites
- `supabase/tests` — invariant and concurrency tests
- `docs/architecture.md` — design notes

## Run the ledger tests
Needs a Postgres 16 server and `psql`:

    DATABASE_URL=******localhost:5432/postgres npm run test:db

Each run creates and drops a throwaway database.
