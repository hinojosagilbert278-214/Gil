\set ON_ERROR_STOP on
-- Deployment-time check. Usage: psql -v allowed="role1,role2" -f ledger_service_members.sql
SELECT set_config('chk.allowed', :'allowed', false) \gset
DO $$
DECLARE
  allowed_roles text[] := regexp_split_to_array(current_setting('chk.allowed'), '\s*,\s*')
    || ARRAY['ledger_service'];
  bad text;
BEGIN
  SELECT string_agg(r.rolname, ', ') INTO bad
    FROM pg_roles r
   WHERE NOT r.rolsuper
     AND r.rolname <> ALL (allowed_roles)
     AND pg_has_role(r.oid, 'ledger_service'::regrole, 'MEMBER');
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected direct or inherited ledger_service members: %', bad;
  END IF;

  SELECT string_agg(DISTINCT r.rolname, ', ') INTO bad
    FROM pg_roles r
   WHERE NOT r.rolsuper
     AND r.rolname <> ALL (allowed_roles)
     AND EXISTS (
       SELECT 1
         FROM pg_proc p
        WHERE p.proname IN ('post_journal', 'ledger_check_replay',
          'ledger_credit_purchase', 'wallet_process_live_gift',
          'family_invite_signature', 'verify_family_invite_signature')
          AND has_function_privilege(r.oid, p.oid, 'EXECUTE')
     );
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'unexpected effective ledger function privileges: %', bad;
  END IF;
END $$;
