-- Trust Blue ledger core. All monetary values are whole BIGINT micro-units.
CREATE TABLE accounts (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  username   VARCHAR(50)  UNIQUE NOT NULL,
  email      VARCHAR(255) UNIQUE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE families (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name       VARCHAR(100) UNIQUE NOT NULL,
  leader_id  BIGINT NOT NULL REFERENCES accounts(id),
  leader_share_percentage INT NOT NULL DEFAULT 5 CHECK (leader_share_percentage BETWEEN 0 AND 10),
  vault_share_percentage  INT NOT NULL DEFAULT 5 CHECK (vault_share_percentage BETWEEN 0 AND 10),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- One family per account (enforced by the unique account_id).
CREATE TABLE family_members (
  family_id   BIGINT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
  account_id  BIGINT NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
  clan_branch VARCHAR(20) NOT NULL CHECK (clan_branch IN ('STREAM','PLAY','PULSE')),
  joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (family_id, account_id)
);

-- Every balance holder: user wallets, family vaults, and system accounts.
CREATE TABLE ledger_accounts (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind          VARCHAR(20) NOT NULL CHECK (kind IN ('USER_WALLET','FAMILY_VAULT','TREASURY','EXTERNAL')),
  owner_account_id BIGINT REFERENCES accounts(id),
  owner_family_id  BIGINT REFERENCES families(id),
  balance_micro BIGINT NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((kind = 'USER_WALLET')  = (owner_account_id IS NOT NULL)),
  CHECK ((kind = 'FAMILY_VAULT') = (owner_family_id IS NOT NULL)),
  -- only the EXTERNAL (money in/out) account may go negative
  CHECK (kind = 'EXTERNAL' OR balance_micro >= 0)
);
CREATE UNIQUE INDEX ledger_accounts_wallet_uq ON ledger_accounts(owner_account_id) WHERE kind = 'USER_WALLET';
CREATE UNIQUE INDEX ledger_accounts_vault_uq  ON ledger_accounts(owner_family_id)  WHERE kind = 'FAMILY_VAULT';
CREATE UNIQUE INDEX ledger_accounts_system_uq ON ledger_accounts(kind) WHERE kind IN ('TREASURY','EXTERNAL');

INSERT INTO ledger_accounts(kind) VALUES ('TREASURY'), ('EXTERNAL');

CREATE TABLE journal_entries (
  id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transaction_uuid UUID UNIQUE NOT NULL,
  entry_type       VARCHAR(50) NOT NULL CHECK (entry_type IN ('WEB_PURCHASE','LIVE_GIFT','SUBSCRIPTION','PAYOUT')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE journal_lines (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  entry_id          BIGINT NOT NULL REFERENCES journal_entries(id),
  ledger_account_id BIGINT NOT NULL REFERENCES ledger_accounts(id),
  amount_micro      BIGINT NOT NULL CHECK (amount_micro <> 0) -- >0 credit, <0 debit
);
CREATE INDEX journal_lines_entry_idx ON journal_lines(entry_id);

CREATE TABLE transactional_outbox (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type    VARCHAR(100) NOT NULL,
  payload       JSONB NOT NULL,
  is_dispatched BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE game_score_audit (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id BIGINT NOT NULL REFERENCES accounts(id),
  game_id    VARCHAR(100) NOT NULL,
  raw_score  DOUBLE PRECISION NOT NULL,
  z_score    DOUBLE PRECISION NOT NULL,
  telemetry_payload JSONB NOT NULL,
  is_flagged_fraud  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Journal is append-only.
CREATE FUNCTION forbid_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END $$;
CREATE TRIGGER journal_entries_immutable BEFORE UPDATE OR DELETE ON journal_entries
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER journal_lines_immutable BEFORE UPDATE OR DELETE ON journal_lines
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- Each entry must balance to zero (checked at commit).
CREATE FUNCTION assert_entry_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT COALESCE(SUM(amount_micro),0) FROM journal_lines WHERE entry_id = NEW.entry_id) <> 0 THEN
    RAISE EXCEPTION 'journal entry % is unbalanced', NEW.entry_id;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER journal_lines_balanced AFTER INSERT ON journal_lines
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION assert_entry_balanced();

-- Auto-create wallet / vault accounts.
CREATE FUNCTION create_wallet() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ledger_accounts(kind, owner_account_id) VALUES ('USER_WALLET', NEW.id); RETURN NEW; END $$;
CREATE TRIGGER accounts_wallet AFTER INSERT ON accounts FOR EACH ROW EXECUTE FUNCTION create_wallet();

CREATE FUNCTION create_vault() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ledger_accounts(kind, owner_family_id) VALUES ('FAMILY_VAULT', NEW.id); RETURN NEW; END $$;
CREATE TRIGGER families_vault AFTER INSERT ON families FOR EACH ROW EXECUTE FUNCTION create_vault();
