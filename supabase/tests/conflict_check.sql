\set ON_ERROR_STOP on
SELECT set_config('t.tx', :'tx', false) \gset
DO $$
DECLARE n int; debit bigint; bal bigint; tx uuid := current_setting('t.tx')::uuid;
BEGIN
  SELECT count(*) INTO n FROM journal_entries WHERE transaction_uuid = tx;
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: % entries for conflicting tx', n; END IF;
  SELECT count(*) INTO n FROM transactional_outbox WHERE payload->>'tx_uuid' = tx::text;
  IF n <> 1 THEN RAISE EXCEPTION 'FAIL: % outbox rows for conflicting tx', n; END IF;
  SELECT -l.amount_micro INTO debit FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
   WHERE e.transaction_uuid = tx AND l.amount_micro < 0;
  SELECT balance_micro INTO bal FROM ledger_accounts WHERE owner_account_id=(SELECT id FROM accounts WHERE username='esender');
  IF bal <> 10000 - debit THEN RAISE EXCEPTION 'FAIL: esender balance % vs debit %', bal, debit; END IF;
  IF (SELECT count(*) FROM journal_lines l JOIN journal_entries e ON e.id=l.entry_id WHERE e.transaction_uuid = tx) < 3 THEN
    RAISE EXCEPTION 'FAIL: missing journal lines'; END IF;
  IF (SELECT sum(balance_micro) FROM ledger_accounts) <> 0 THEN RAISE EXCEPTION 'FAIL: conservation violated'; END IF;
END $$;
