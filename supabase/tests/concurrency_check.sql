\set ON_ERROR_STOP on
DO $$
DECLARE s bigint; n int;
BEGIN
  SELECT balance_micro INTO s FROM ledger_accounts WHERE owner_account_id=(SELECT id FROM accounts WHERE username='csender');
  SELECT count(*) INTO n FROM journal_entries WHERE entry_type='LIVE_GIFT'
    AND id IN (SELECT entry_id FROM journal_lines WHERE ledger_account_id=(SELECT id FROM ledger_accounts WHERE owner_account_id=(SELECT id FROM accounts WHERE username='csender')));
  IF s < 0 THEN RAISE EXCEPTION 'FAIL: negative balance %', s; END IF;
  IF n <> 10 OR s <> 0 THEN RAISE EXCEPTION 'FAIL: expected exactly 10 gifts and 0 left, got % gifts, balance %', n, s; END IF;
  IF (SELECT sum(balance_micro) FROM ledger_accounts) <> 0 THEN RAISE EXCEPTION 'FAIL: conservation violated'; END IF;
END $$;
