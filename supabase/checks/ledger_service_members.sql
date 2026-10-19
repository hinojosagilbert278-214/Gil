\set ON_ERROR_STOP on
-- Deployment-time check. Usage: psql -v allowed="role1,role2" -f ledger_service_members.sql
SELECT set_config('chk.allowed', :'allowed', false) \gset
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(m.rolname, ', ') INTO bad
    FROM pg_auth_members am
    JOIN pg_roles m ON m.oid = am.member
   WHERE am.roleid = 'ledger_service'::regrole
     AND m.rolname <> ALL (string_to_array(current_setting('chk.allowed'), ','));
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected ledger_service members: %', bad;
  END IF;
END $$;
