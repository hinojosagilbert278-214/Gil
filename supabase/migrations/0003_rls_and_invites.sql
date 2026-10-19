CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Resolves the caller from the verified JWT subject (PostgREST/Supabase set
-- request.jwt.claim.sub from the signature-checked token; clients cannot set it
-- because they have no direct SQL access). On Supabase auth.uid() is equivalent.
-- Unknown or missing subjects resolve to NULL, which matches no rows.
CREATE FUNCTION current_account_id() RETURNS BIGINT LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_sub TEXT := NULLIF(current_setting('request.jwt.claim.sub', true), '');
BEGIN
  IF v_sub IS NULL THEN RETURN NULL; END IF;
  RETURN (SELECT id FROM accounts WHERE auth_user_id = v_sub::uuid);
EXCEPTION WHEN invalid_text_representation THEN RETURN NULL;
END $$;

-- SECURITY DEFINER avoids recursive RLS evaluation on family_members.
CREATE FUNCTION my_family_ids() RETURNS SETOF BIGINT LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT family_id FROM family_members WHERE account_id = current_account_id() $$;

ALTER TABLE family_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY family_isolation_select ON family_members FOR SELECT
  USING (family_id IN (SELECT my_family_ids()));

ALTER TABLE ledger_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_wallet_select ON ledger_accounts FOR SELECT
  USING (owner_account_id = current_account_id()
         OR owner_family_id IN (SELECT my_family_ids()));

ALTER TABLE journal_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_lines_select ON journal_lines FOR SELECT
  USING (ledger_account_id IN (SELECT id FROM ledger_accounts));

-- Invite signature. The secret is read from a server-side setting, never a parameter.
CREATE FUNCTION family_invite_signature(p_family BIGINT, p_target BIGINT, p_expires TIMESTAMPTZ)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT encode(hmac(
    p_family::text || '|' || p_target::text || '|' ||
      to_char(p_expires AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    current_setting('app.invite_secret'), 'sha256'), 'hex') $$;

CREATE FUNCTION verify_family_invite_signature(p_family BIGINT, p_target BIGINT, p_expires TIMESTAMPTZ, p_sig TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_expected TEXT := family_invite_signature(p_family, p_target, p_expires); v_diff INT := 0; i INT;
BEGIN
  IF now() > p_expires OR p_sig IS NULL OR length(p_sig) <> length(v_expected) THEN RETURN FALSE; END IF;
  FOR i IN 1..length(v_expected) LOOP  -- constant-time comparison
    v_diff := v_diff | (ascii(substr(v_expected, i, 1)) # ascii(substr(p_sig, i, 1)));
  END LOOP;
  RETURN v_diff = 0;
END $$;

-- Invite signing/verification are server-side only (they read the secret).
REVOKE ALL ON FUNCTION family_invite_signature(BIGINT, BIGINT, TIMESTAMPTZ),
  verify_family_invite_signature(BIGINT, BIGINT, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION family_invite_signature(BIGINT, BIGINT, TIMESTAMPTZ),
  verify_family_invite_signature(BIGINT, BIGINT, TIMESTAMPTZ, TEXT) TO ledger_service;
