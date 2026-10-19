\set ON_ERROR_STOP on
CREATE FUNCTION expect(cond BOOLEAN, msg TEXT) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(cond,false) THEN RAISE EXCEPTION 'FAIL: %', msg; END IF; END $$;

INSERT INTO accounts(username,email,auth_user_id) VALUES ('leader','l@x',gen_random_uuid()),('creator','c@x',gen_random_uuid()),('fan','f@x',gen_random_uuid()),('solo','s@x',gen_random_uuid()),('outsider','o@x',gen_random_uuid());
INSERT INTO families(name, leader_id) SELECT 'Clan', id FROM accounts WHERE username='leader';
INSERT INTO family_members(family_id, account_id, clan_branch)
  SELECT (SELECT id FROM families), id, 'STREAM' FROM accounts WHERE username IN ('leader','creator');

CREATE FUNCTION aid(u text) RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM accounts WHERE username=u $$;
CREATE FUNCTION bal(u text) RETURNS bigint LANGUAGE sql AS $$
  SELECT balance_micro FROM ledger_accounts WHERE owner_account_id = aid(u) $$;

SELECT ledger_credit_purchase('00000000-0000-0000-0000-000000000001', aid('fan'), 10000);
SELECT expect(bal('fan') = 10000, 'purchase credits wallet');

-- Family gift: 1000 -> creator share 700 -> vault 35, leader 35, creator 630, treasury 300
SELECT wallet_process_live_gift('00000000-0000-0000-0000-000000000002', aid('fan'), aid('creator'), 1000);
SELECT expect(bal('fan') = 9000, 'sender debited');
SELECT expect(bal('creator') = 630, 'creator net');
SELECT expect(bal('leader') = 35, 'leader cut');
SELECT expect((SELECT balance_micro FROM ledger_accounts WHERE kind='FAMILY_VAULT') = 35, 'vault cut');
SELECT expect((SELECT balance_micro FROM ledger_accounts WHERE kind='TREASURY') = 300, 'treasury');

-- Idempotent replay changes nothing
SELECT wallet_process_live_gift('00000000-0000-0000-0000-000000000002', aid('fan'), aid('creator'), 1000);
SELECT expect(bal('fan') = 9000, 'replay is a no-op');
SELECT expect((SELECT count(*) FROM journal_entries WHERE entry_type='LIVE_GIFT') = 1, 'single entry');
SELECT expect((SELECT count(*) FROM transactional_outbox) = 1, 'single outbox event');

-- Replay with a different request is rejected
DO $$ BEGIN
  BEGIN PERFORM wallet_process_live_gift('00000000-0000-0000-0000-000000000002', aid('fan'), aid('creator'), 999);
    RAISE EXCEPTION 'FAIL: mismatched replay accepted';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  BEGIN PERFORM wallet_process_live_gift('00000000-0000-0000-0000-000000000002', aid('fan'), aid('solo'), 1000);
    RAISE EXCEPTION 'FAIL: mismatched replay (other creator) accepted';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  BEGIN PERFORM ledger_credit_purchase('00000000-0000-0000-0000-000000000002', aid('fan'), 1000);
    RAISE EXCEPTION 'FAIL: cross-type replay accepted';
  EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;
-- Outbox key is unique
DO $$ BEGIN
  BEGIN INSERT INTO transactional_outbox(idempotency_key,event_type,payload)
    SELECT idempotency_key,'X','{}' FROM transactional_outbox LIMIT 1;
    RAISE EXCEPTION 'FAIL: duplicate outbox key accepted';
  EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;

-- Non-family gift with odd amount: still conserves
SELECT wallet_process_live_gift('00000000-0000-0000-0000-000000000003', aid('fan'), aid('solo'), 7);
SELECT expect(bal('solo') = 4, 'solo creator share floor(7*70/100)=4');

-- Conservation: global sum of balances is zero; every entry balances
SELECT expect((SELECT sum(balance_micro) FROM ledger_accounts) = 0, 'global conservation');
SELECT expect((SELECT count(*) FROM (SELECT entry_id FROM journal_lines GROUP BY entry_id HAVING sum(amount_micro) <> 0) x) = 0, 'entries balance');
SELECT expect((SELECT bool_and(a.balance_micro = COALESCE(l.s,0)) FROM ledger_accounts a
  LEFT JOIN (SELECT ledger_account_id, sum(amount_micro) s FROM journal_lines GROUP BY 1) l ON l.ledger_account_id=a.id), 'cached balances match journal');

-- Insufficient funds / bad input fail atomically
DO $$ BEGIN
  BEGIN PERFORM wallet_process_live_gift(gen_random_uuid(), aid('solo'), aid('creator'), 999999);
    RAISE EXCEPTION 'FAIL: overdraft allowed';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN PERFORM wallet_process_live_gift(gen_random_uuid(), aid('fan'), aid('creator'), 0);
    RAISE EXCEPTION 'FAIL: zero amount allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF; END;
END $$;

-- Append-only journal
DO $$ BEGIN
  BEGIN UPDATE journal_lines SET amount_micro = 1; RAISE EXCEPTION 'FAIL: update allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF; END;
  BEGIN DELETE FROM journal_entries; RAISE EXCEPTION 'FAIL: delete allowed';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF; END;
END $$;

-- Unbalanced entry rejected at commit
DO $$ BEGIN
  BEGIN
    PERFORM post_journal(gen_random_uuid(), 'PAYOUT', 'fp', jsonb_build_array(
      jsonb_build_object('ledger_account_id',(SELECT id FROM ledger_accounts WHERE kind='TREASURY'),'amount_micro',-1)));
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'FAIL: unbalanced accepted';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF; END;
END $$;

-- Invite signatures
SET app.invite_secret = 'test-secret';
SELECT expect(verify_family_invite_signature(1, aid('outsider'), now() + interval '1 hour',
  family_invite_signature(1, aid('outsider'), date_trunc('second', now() + interval '1 hour'))) IS NOT NULL, 'invite runs');
DO $$ DECLARE e timestamptz := date_trunc('second', now() + interval '1 hour'); BEGIN
  PERFORM expect(verify_family_invite_signature(1, 5, e, family_invite_signature(1, 5, e)), 'valid sig');
  PERFORM expect(NOT verify_family_invite_signature(1, 6, e, family_invite_signature(1, 5, e)), 'wrong target rejected');
  PERFORM expect(NOT verify_family_invite_signature(1, 5, now() - interval '1 s', family_invite_signature(1, 5, now() - interval '1 s')), 'expired rejected');
END $$;

-- RLS: a non-superuser sees only own family; outsider sees nothing
DROP ROLE IF EXISTS app_user;
CREATE ROLE app_user NOLOGIN;
GRANT SELECT ON accounts TO app_user;
GRANT SELECT ON family_members, ledger_accounts, journal_lines TO app_user;
GRANT EXECUTE ON FUNCTION current_account_id(), my_family_ids() TO app_user;
CREATE TEMP TABLE ids AS SELECT (SELECT auth_user_id FROM accounts WHERE username='creator') c, (SELECT auth_user_id FROM accounts WHERE username='outsider') o;
GRANT SELECT ON ids TO app_user;
SET ROLE app_user;
SELECT set_config('request.jwt.claim.sub', (SELECT c FROM ids)::text, false);
SELECT expect((SELECT count(*) FROM family_members) = 2, 'member sees own family');
SELECT set_config('request.jwt.claim.sub', (SELECT o FROM ids)::text, false);
SELECT expect((SELECT count(*) FROM family_members) = 0, 'outsider sees no family rows');
SELECT expect((SELECT count(*) FROM ledger_accounts) = 1, 'outsider sees only own wallet');
SELECT set_config('request.jwt.claim.sub', 'not-a-uuid', false);
SELECT expect((SELECT count(*) FROM ledger_accounts) = 0, 'garbage subject sees nothing');
SELECT set_config('request.jwt.claim.sub', '', false);
SELECT expect((SELECT count(*) FROM family_members) = 0, 'no subject sees nothing');
-- Untrusted role cannot post to the ledger or read the invite secret path
DO $$ BEGIN
  BEGIN PERFORM wallet_process_live_gift(gen_random_uuid(), 1, 2, 10); RAISE EXCEPTION 'FAIL: app_user executed gift';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM post_journal(gen_random_uuid(), 'PAYOUT', 'x', '[]'); RAISE EXCEPTION 'FAIL: app_user executed post_journal';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM ledger_credit_purchase(gen_random_uuid(), 1, 10); RAISE EXCEPTION 'FAIL: app_user executed purchase';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM family_invite_signature(1, 2, now()); RAISE EXCEPTION 'FAIL: app_user executed invite signing';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
RESET ROLE;
DROP OWNED BY app_user;
DROP ROLE app_user;
