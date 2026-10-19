CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Authenticated user id comes from the request-scoped setting `app.user_id`
-- (on Supabase, replace with auth.uid()).
CREATE FUNCTION current_account_id() RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::bigint $$;

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
