-- ============================================================================
-- 070_071_state_transition_check.sql
--
-- 田島様2026-08-10ご指摘⑧への対応。状態遷移専用の検証スクリプト。
--
-- migration 070（post_record_pending 始点の2遷移を不許可・保留3項目を必須）と
-- migration 071（保留・再開の監査記録と保護）が、実際の権限（authenticated）で
-- 意図どおり動作することを、肯定・否定の両方向から検査する。
--
-- 【本ファイルの性質（重要）】
--   本ファイルは他の *_check.sql と異なり、**書き込みを伴う**。
--   検査用の agency_config・operator・run・auth.users を作成し、実際に
--   UPDATE を試行して受理・拒否を確認する。
--   すべての操作は単一のトランザクション内で行い、最後に RAISE EXCEPTION で
--   結果を返してロールバックするため、データベースには何も残らない。
--   それでも、**本番では実行しないこと**（田島様2026-08-08ご指摘2の方針に従い、
--   分離検証環境専用とする）。run_all_checks.sh の対象にも含めない。
--
-- 【なぜロール切替が必須か】
--   既定の接続ロールは postgres（rolbypassrls=true）であり、RLSを評価せず、
--   トリガー内の current_user = 'authenticated' 分岐にも入らない。
--   ロールを切り替えずに「拒否された」と判断すると、実際には素通りする経路を
--   合格として報告することになる。本スクリプトは SET LOCAL ROLE authenticated と
--   request.jwt.claim.sub の設定を必ず行う。
--
-- 【拒否の根拠を取り違えないための注意】
--   期待する拒否は、いずれもトリガーの RAISE EXCEPTION による P0001 である。
--   42501（権限不足）や 23503（外部キー違反）、あるいは「0件更新」は
--   トリガーが拒否したことを意味しない。本スクリプトは SQLSTATE を確認し、
--   0件更新と例外を明確に区別する。
--
-- 実行方法:
--   psql "<検証環境の接続文字列>" -f supabase/verification/070_071_state_transition_check.sql
-- 期待する結果:
--   P0001 の例外として結果一覧が出力され、全10件が PASS であること。
--   1件でも FAIL があれば、その行に理由が出力される。
-- ============================================================================

DO $test$
DECLARE
  v_agency uuid := gen_random_uuid();
  v_auth   uuid := gen_random_uuid();
  v_op     uuid := gen_random_uuid();
  r_prp1 uuid := gen_random_uuid();
  r_prp2 uuid := gen_random_uuid();
  r_prp3 uuid := gen_random_uuid();
  r_d1 uuid := gen_random_uuid();
  r_d2 uuid := gen_random_uuid();
  r_d3 uuid := gen_random_uuid();
  r_d4 uuid := gen_random_uuid();
  v_res text := E'\n';
  v_fail int := 0;
  v_n int;
  v_cnt int;
  v_sqlstate text;
BEGIN
  -- ── 検査データの作成（postgres として） ──────────────────────────────
  INSERT INTO auth.users (id, email) VALUES (v_auth, 'state-transition-check@example.invalid');
  INSERT INTO public.agency_config (agency_id, agency_name) VALUES (v_agency, 'StateTransitionCheck');
  INSERT INTO public.operator (id, agency_id, name, license_number, role, is_active, auth_user_id)
    VALUES (v_op, v_agency, 'Checker', 'LIC-CHECK', 'admin', true, v_auth);
  INSERT INTO public.run (id, agency_id, operator_id, customer_type, customer_ref, run_type, run_status)
    VALUES (r_prp1, v_agency, v_op, 'individual', 'C1', 'new_contract', 'post_record_pending'),
           (r_prp2, v_agency, v_op, 'individual', 'C2', 'new_contract', 'post_record_pending'),
           (r_prp3, v_agency, v_op, 'individual', 'C3', 'new_contract', 'post_record_pending'),
           (r_d1,   v_agency, v_op, 'individual', 'C4', 'new_contract', 'draft'),
           (r_d2,   v_agency, v_op, 'individual', 'C5', 'new_contract', 'draft'),
           (r_d3,   v_agency, v_op, 'individual', 'C6', 'new_contract', 'draft'),
           (r_d4,   v_agency, v_op, 'individual', 'C7', 'new_contract', 'draft');

  -- ── 実際の権限へ切り替える ────────────────────────────────────────────
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  SET LOCAL ROLE authenticated;

  IF current_user <> 'authenticated' THEN
    RAISE EXCEPTION 'state transition check aborted: role switch failed (current_user=%)', current_user;
  END IF;

  -- ── T1 (070) post_record_pending -> suspended は拒否されること ────────
  BEGIN
    UPDATE public.run SET run_status='suspended', suspension_type='mid_session',
           pending_note='x', suspended_at=now() WHERE id=r_prp1;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := v_res || format('T1  post_record_pending -> suspended : FAIL 拒否されなかった (rows=%s)%s', v_n, E'\n');
    v_fail := v_fail + 1;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate = 'P0001' THEN
      v_res := v_res || format('T1  post_record_pending -> suspended : PASS 拒否 [%s]%s', v_sqlstate, E'\n');
    ELSE
      v_res := v_res || format('T1  post_record_pending -> suspended : FAIL 拒否理由が不正 [%s]%s', v_sqlstate, E'\n');
      v_fail := v_fail + 1;
    END IF;
  END;

  -- ── T2 (070) post_record_pending -> draft は拒否されること ────────────
  BEGIN
    UPDATE public.run SET run_status='draft' WHERE id=r_prp2;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := v_res || format('T2  post_record_pending -> draft     : FAIL 拒否されなかった (rows=%s)%s', v_n, E'\n');
    v_fail := v_fail + 1;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate = 'P0001' THEN
      v_res := v_res || format('T2  post_record_pending -> draft     : PASS 拒否 [%s]%s', v_sqlstate, E'\n');
    ELSE
      v_res := v_res || format('T2  post_record_pending -> draft     : FAIL 拒否理由が不正 [%s]%s', v_sqlstate, E'\n');
      v_fail := v_fail + 1;
    END IF;
  END;

  -- ── T3 (070/071) draft -> suspended は受理され、監査記録が残ること ────
  BEGIN
    UPDATE public.run SET run_status='suspended', suspension_type='condition_adjustment',
           pending_note='条件を再確認するため', suspended_at=now() WHERE id=r_d1;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    SELECT count(*) INTO v_cnt FROM public.audit_event
      WHERE run_id=r_d1 AND event_type='run_suspended' AND operator_id=v_op
        AND payload->>'previous_run_status' = 'draft'
        AND payload->>'suspension_type' = 'condition_adjustment'
        AND payload->>'pending_note' IS NOT NULL
        AND payload->>'suspended_at' IS NOT NULL;
    IF v_n=1 AND v_cnt=1 THEN
      v_res := v_res || format('T3  draft -> suspended               : PASS 受理＋監査記録%s', E'\n');
    ELSE
      v_res := v_res || format('T3  draft -> suspended               : FAIL (rows=%s, audit=%s)%s', v_n, v_cnt, E'\n');
      v_fail := v_fail + 1;
    END IF;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_res := v_res || format('T3  draft -> suspended               : FAIL 拒否された [%s] %s%s', v_sqlstate, SQLERRM, E'\n');
    v_fail := v_fail + 1;
  END;

  -- ── T4 (070) 保留メモが無い保留は拒否されること（ご指摘②） ────────────
  BEGIN
    UPDATE public.run SET run_status='suspended', suspension_type='mid_session',
           pending_note=NULL, suspended_at=now() WHERE id=r_d2;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := v_res || format('T4  保留メモ無しの保留               : FAIL 拒否されなかった (rows=%s)%s', v_n, E'\n');
    v_fail := v_fail + 1;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate = 'P0001' THEN
      v_res := v_res || format('T4  保留メモ無しの保留               : PASS 拒否 [%s]%s', v_sqlstate, E'\n');
    ELSE
      v_res := v_res || format('T4  保留メモ無しの保留               : FAIL 拒否理由が不正 [%s]%s', v_sqlstate, E'\n');
      v_fail := v_fail + 1;
    END IF;
  END;

  -- ── T5 (071) 再開が受理され、監査記録が残ること ───────────────────────
  BEGIN
    UPDATE public.run SET run_status='draft', suspension_type=NULL,
           pending_note=NULL, suspended_at=NULL WHERE id=r_d1;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    SELECT count(*) INTO v_cnt FROM public.audit_event
      WHERE run_id=r_d1 AND event_type='run_resumed' AND operator_id=v_op
        AND payload->>'previous_run_status' = 'suspended'
        AND payload->>'new_run_status' = 'draft';
    IF v_n=1 AND v_cnt=1 THEN
      v_res := v_res || format('T5  suspended -> draft（再開）        : PASS 受理＋監査記録%s', E'\n');
    ELSE
      v_res := v_res || format('T5  suspended -> draft（再開）        : FAIL (rows=%s, audit=%s)%s', v_n, v_cnt, E'\n');
      v_fail := v_fail + 1;
    END IF;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_res := v_res || format('T5  suspended -> draft（再開）        : FAIL 拒否された [%s] %s%s', v_sqlstate, SQLERRM, E'\n');
    v_fail := v_fail + 1;
  END;

  -- ── T6 承認済みの draft -> post_record_pending が維持されていること ────
  BEGIN
    UPDATE public.run SET run_status='post_record_pending' WHERE id=r_d3;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n=1 THEN
      v_res := v_res || format('T6  draft -> post_record_pending     : PASS 受理%s', E'\n');
    ELSE
      v_res := v_res || format('T6  draft -> post_record_pending     : FAIL (rows=%s)%s', v_n, E'\n');
      v_fail := v_fail + 1;
    END IF;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_res := v_res || format('T6  draft -> post_record_pending     : FAIL 拒否された [%s]%s', v_sqlstate, E'\n');
    v_fail := v_fail + 1;
  END;

  -- ── T7 (068) draft -> archived が拒否されたままであること ─────────────
  BEGIN
    UPDATE public.run SET run_status='archived' WHERE id=r_d4;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := v_res || format('T7  draft -> archived                : FAIL 拒否されなかった (rows=%s)%s', v_n, E'\n');
    v_fail := v_fail + 1;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate = 'P0001' THEN
      v_res := v_res || format('T7  draft -> archived                : PASS 拒否 [%s]%s', v_sqlstate, E'\n');
    ELSE
      v_res := v_res || format('T7  draft -> archived                : FAIL 拒否理由が不正 [%s]%s', v_sqlstate, E'\n');
      v_fail := v_fail + 1;
    END IF;
  END;

  -- ── T8 (068) post_record_pending -> archived が拒否されたままであること ─
  BEGIN
    UPDATE public.run SET run_status='archived' WHERE id=r_prp3;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := v_res || format('T8  post_record_pending -> archived  : FAIL 拒否されなかった (rows=%s)%s', v_n, E'\n');
    v_fail := v_fail + 1;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate = 'P0001' THEN
      v_res := v_res || format('T8  post_record_pending -> archived  : PASS 拒否 [%s]%s', v_sqlstate, E'\n');
    ELSE
      v_res := v_res || format('T8  post_record_pending -> archived  : FAIL 拒否理由が不正 [%s]%s', v_sqlstate, E'\n');
      v_fail := v_fail + 1;
    END IF;
  END;

  -- ── T9 (071) 保留イベントの直接INSERTが拒否されること ─────────────────
  BEGIN
    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
      VALUES (r_d4, 'run_suspended', v_op, '{}'::jsonb);
    v_res := v_res || format('T9  audit_event 直接INSERT           : FAIL 受理された%s', E'\n');
    v_fail := v_fail + 1;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate = 'P0001' THEN
      v_res := v_res || format('T9  audit_event 直接INSERT           : PASS 拒否 [%s]%s', v_sqlstate, E'\n');
    ELSE
      v_res := v_res || format('T9  audit_event 直接INSERT           : FAIL 拒否理由が不正 [%s]%s', v_sqlstate, E'\n');
      v_fail := v_fail + 1;
    END IF;
  END;

  -- ── T10 (ご指摘③) 対象行が無い更新は例外にならず0件で返ること ─────────
  --      画面はこの0件を失敗として扱わなければならない。
  BEGIN
    UPDATE public.run SET run_status='suspended', suspension_type='mid_session',
           pending_note='x', suspended_at=now() WHERE id=gen_random_uuid();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n=0 THEN
      v_res := v_res || format('T10 対象行なしの更新                 : PASS 例外にならず0件（画面側で失敗扱いが必要）%s', E'\n');
    ELSE
      v_res := v_res || format('T10 対象行なしの更新                 : FAIL (rows=%s)%s', v_n, E'\n');
      v_fail := v_fail + 1;
    END IF;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    v_res := v_res || format('T10 対象行なしの更新                 : FAIL 例外が発生した [%s]%s', v_sqlstate, E'\n');
    v_fail := v_fail + 1;
  END;

  RESET ROLE;

  v_res := v_res || format('%s合計: 10件中 %s件 FAIL%s', E'\n', v_fail, E'\n');
  IF v_fail > 0 THEN
    RAISE EXCEPTION E'状態遷移検証: 失敗あり（すべてロールバック済み）%', v_res;
  END IF;
  RAISE EXCEPTION E'状態遷移検証: 全件 PASS（すべてロールバック済み）%', v_res;
END;
$test$;
