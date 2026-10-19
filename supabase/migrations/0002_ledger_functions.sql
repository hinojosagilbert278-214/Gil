DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_service') THEN
    CREATE ROLE ledger_service NOLOGIN;
  END IF;
END $$;

-- Returns the existing entry id for a replayed tx, NULL if new.
-- Raises if the tx uuid was used for a different request.
CREATE FUNCTION ledger_check_replay(p_tx UUID, p_fingerprint TEXT) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id BIGINT; v_fp TEXT;
BEGIN
  SELECT id, request_fingerprint INTO v_id, v_fp FROM journal_entries WHERE transaction_uuid = p_tx;
  IF v_id IS NULL THEN RETURN NULL; END IF;
  IF v_fp <> p_fingerprint THEN
    RAISE EXCEPTION 'transaction_uuid % reused with a different request', p_tx USING ERRCODE = 'unique_violation';
  END IF;
  RETURN v_id;
END $$;

-- post_journal: idempotent, balanced, deadlock-safe posting.
-- p_lines: [{"ledger_account_id": n, "amount_micro": n}, ...]
CREATE FUNCTION post_journal(p_tx UUID, p_type TEXT, p_fingerprint TEXT, p_lines JSONB) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_entry BIGINT; v_line RECORD;
BEGIN
  INSERT INTO journal_entries(transaction_uuid, entry_type, request_fingerprint)
    VALUES (p_tx, p_type, p_fingerprint)
    ON CONFLICT (transaction_uuid) DO NOTHING RETURNING id INTO v_entry;
  IF v_entry IS NULL THEN
    RETURN ledger_check_replay(p_tx, p_fingerprint);
  END IF;

  PERFORM 1 FROM ledger_accounts
   WHERE id IN (SELECT (l->>'ledger_account_id')::bigint FROM jsonb_array_elements(p_lines) l)
   ORDER BY id FOR UPDATE;

  FOR v_line IN
    SELECT (l->>'ledger_account_id')::bigint AS acct, (l->>'amount_micro')::bigint AS amt
      FROM jsonb_array_elements(p_lines) l WHERE (l->>'amount_micro')::bigint <> 0
  LOOP
    INSERT INTO journal_lines(entry_id, ledger_account_id, amount_micro) VALUES (v_entry, v_line.acct, v_line.amt);
    UPDATE ledger_accounts SET balance_micro = balance_micro + v_line.amt, updated_at = now() WHERE id = v_line.acct;
  END LOOP;
  RETURN v_entry;
END $$;

CREATE FUNCTION ledger_fingerprint(VARIADIC p_parts TEXT[]) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(array_to_string(p_parts, '|'), 'UTF8')), 'hex') $$;

-- Top up a wallet from outside (web purchase). Debits EXTERNAL.
CREATE FUNCTION ledger_credit_purchase(p_tx UUID, p_account BIGINT, p_amount BIGINT) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_wallet BIGINT; v_ext BIGINT; v_fp TEXT; v_existing BIGINT;
BEGIN
  v_fp := ledger_fingerprint('WEB_PURCHASE', p_account::text, p_amount::text);
  v_existing := ledger_check_replay(p_tx, v_fp);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'amount must be positive'; END IF;
  SELECT id INTO v_wallet FROM ledger_accounts WHERE kind='USER_WALLET' AND owner_account_id = p_account;
  SELECT id INTO v_ext FROM ledger_accounts WHERE kind='EXTERNAL';
  IF v_wallet IS NULL THEN RAISE EXCEPTION 'unknown account'; END IF;
  RETURN post_journal(p_tx, 'WEB_PURCHASE', v_fp, jsonb_build_array(
    jsonb_build_object('ledger_account_id', v_ext,    'amount_micro', -p_amount),
    jsonb_build_object('ledger_account_id', v_wallet, 'amount_micro',  p_amount)));
END $$;

-- Live gift: sender pays total; 70% to creator side, 30% to treasury.
-- If the creator is in a family, vault and leader cuts come out of the creator's 70%.
CREATE FUNCTION wallet_process_live_gift(p_tx UUID, p_sender BIGINT, p_creator BIGINT, p_total BIGINT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_existing BIGINT; v_entry BIGINT; v_fp TEXT;
  v_sender_w BIGINT; v_creator_w BIGINT; v_treasury BIGINT;
  v_creator_share BIGINT; v_treasury_share BIGINT;
  v_family BIGINT; v_leader BIGINT; v_leader_pct INT; v_vault_pct INT;
  v_vault_acct BIGINT; v_leader_w BIGINT;
  v_vault_cut BIGINT := 0; v_leader_cut BIGINT := 0; v_final BIGINT;
  v_lines JSONB;
BEGIN
  v_fp := ledger_fingerprint('LIVE_GIFT', p_sender::text, p_creator::text, p_total::text);
  v_existing := ledger_check_replay(p_tx, v_fp);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  IF p_total <= 0 THEN RAISE EXCEPTION 'amount must be positive'; END IF;
  IF p_sender = p_creator THEN RAISE EXCEPTION 'cannot gift yourself'; END IF;

  SELECT id INTO v_sender_w  FROM ledger_accounts WHERE kind='USER_WALLET' AND owner_account_id = p_sender;
  SELECT id INTO v_creator_w FROM ledger_accounts WHERE kind='USER_WALLET' AND owner_account_id = p_creator;
  SELECT id INTO v_treasury  FROM ledger_accounts WHERE kind='TREASURY';
  IF v_sender_w IS NULL OR v_creator_w IS NULL THEN RAISE EXCEPTION 'unknown account'; END IF;

  v_creator_share  := (p_total * 70) / 100;
  v_treasury_share := p_total - v_creator_share;

  SELECT f.id, f.leader_id, f.leader_share_percentage, f.vault_share_percentage
    INTO v_family, v_leader, v_leader_pct, v_vault_pct
    FROM family_members fm JOIN families f ON f.id = fm.family_id
   WHERE fm.account_id = p_creator;

  v_final := v_creator_share;
  v_lines := jsonb_build_array(
    jsonb_build_object('ledger_account_id', v_sender_w, 'amount_micro', -p_total),
    jsonb_build_object('ledger_account_id', v_treasury, 'amount_micro', v_treasury_share));

  IF v_family IS NOT NULL THEN
    SELECT id INTO v_vault_acct FROM ledger_accounts WHERE kind='FAMILY_VAULT' AND owner_family_id = v_family;
    SELECT id INTO v_leader_w   FROM ledger_accounts WHERE kind='USER_WALLET'  AND owner_account_id = v_leader;
    v_vault_cut  := (v_creator_share * v_vault_pct)  / 100;
    IF v_leader <> p_creator THEN v_leader_cut := (v_creator_share * v_leader_pct) / 100; END IF;
    v_final := v_creator_share - v_vault_cut - v_leader_cut;
    v_lines := v_lines
      || jsonb_build_object('ledger_account_id', v_vault_acct, 'amount_micro', v_vault_cut)
      || jsonb_build_object('ledger_account_id', v_leader_w,   'amount_micro', v_leader_cut);
  END IF;
  v_lines := v_lines || jsonb_build_object('ledger_account_id', v_creator_w, 'amount_micro', v_final);

  v_entry := post_journal(p_tx, 'LIVE_GIFT', v_fp, v_lines);

  INSERT INTO transactional_outbox(idempotency_key, event_type, payload)
  VALUES ('LIVE_GIFT_PROCESSED:' || p_tx, 'LIVE_GIFT_PROCESSED', jsonb_build_object('tx_uuid', p_tx, 'creator_id', p_creator,
         'sender_id', p_sender, 'creator_received_micro', v_final,
         'family_vault_received_micro', v_vault_cut, 'family_leader_received_micro', v_leader_cut))
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN v_entry;
END $$;

-- Only the trusted server role may post to the ledger.
REVOKE ALL ON FUNCTION ledger_check_replay(UUID, TEXT), post_journal(UUID, TEXT, TEXT, JSONB),
  ledger_credit_purchase(UUID, BIGINT, BIGINT), wallet_process_live_gift(UUID, BIGINT, BIGINT, BIGINT)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger_credit_purchase(UUID, BIGINT, BIGINT),
  wallet_process_live_gift(UUID, BIGINT, BIGINT, BIGINT) TO ledger_service;
