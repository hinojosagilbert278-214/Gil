\set ON_ERROR_STOP on
SELECT set_config('t.tx', :'tx', false) \gset
DO $$
DECLARE s bigint; n int;
BEGIN
  SELECT balance_micro INTO s FROM ledger_accounts WHERE owner_account_id=(SELECT id FROM accounts WHERE username='csender');
  IF s <> 0 THEN RAISE EXCEPTION 'FAIL: csender balance % (expected 0)', s; END IF;
  SELECT count(*) INTO n FROM journal_lines WHERE ledger_account_id=(SELECT id FROM ledger_accounts WHERE owner_account_id=(SELECT id FROM accounts WHERE username='csender')) AND amount_micro < 0;
  IF n <> 10 THEN RAISE EXCEPTION 'FAIL: expected 10 debits, got %', n; END IF;
  -- duplicate-tx race: one debit, balance 900, one entry, one outbox row
  SELECT balance_micro INTO s FROM ledger_accounts WHERE owner_account_id=(SELECT id FROM accounts WHERE username='dsender');
  IF s <> 900 THEN RAISE EXCEPTION 'FAIL: dsender balance % (expected 900)', s; END IF;
  SELECT count(*) INTO n FROM journal_entries WHERE transaction_uuid = current_setting('t.tx')::uuid;
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: % entries for duplicated tx', n; END IF;
  SELECT count(*) INTO n FROM transactional_outbox WHERE payload->>'tx_uuid' = current_setting('t.tx');
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: % outbox rows for duplicated tx', n; END IF;
  IF (SELECT sum(balance_micro) FROM ledger_accounts) <> 0 THEN RAISE EXCEPTION 'FAIL: conservation violated'; END IF;
END $$;
