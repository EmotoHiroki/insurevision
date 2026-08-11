-- ============================================================================
-- 075_b1_ms1_deactivate_seed_user_operator.sql
--
-- 田島様 判断事項2（seed-user 由来の operator 行の後始末）への対応。
--
-- 【ご判断の内容】
--   seed-user 由来の operator 行を、operator ID で限定した新しい migration で
--   `is_active=false` とすること。変更後も run 12件・監査記録261件の保持を確認すること。
--
-- 【対象の特定根拠】
--   別紙「seed-user Edge Function およびテストアカウント削除 実施記録」§1.3 のとおり、
--   seed-user 由来の operator 行は次の1件のみである。
--
--     operator id : e4248068-1c1a-49e4-89fe-50d53f84268f
--     この operator が確定した run          : 12件
--     この operator を参照する audit_event  : 261件
--
--   2026-08-08の認証アカウント削除により、外部キー `operator.auth_user_id` →
--   `auth.users.id` が ON DELETE SET NULL であるため、当該行は
--   `auth_user_id` が NULL・`is_active` が true のまま残っていた（同記録§6.1）。
--   各RPCは `auth_user_id = auth.uid() AND is_active = true` で操作者を解決するため
--   実害はないが、状態としては不整合であり、`is_active=false` とすることが望ましい。
--
--   なお同記録§5のとおり、本番に残る他の operator 行は
--   2026-07-28〜29の二代理店テストで作成したものであり、seed-user 由来ではない。
--   それらは判断事項3（テスト用アカウントの整理）の対象であり、本migrationでは扱わない。
--
-- 【業務データを消さないこと】
--   本migrationは operator 行を削除しない。`is_active` を false にするのみである。
--   `run.operator_id`・`run.finalized_by`・`audit_event.operator_id` はいずれも
--   ON DELETE NO ACTION であり、確定済み run と監査記録は参照先を保ったまま保持される。
--
-- 既存migrationは編集していない。本ファイルのみを追加する。
-- ============================================================================

DO $apply$
DECLARE
    v_op        uuid := 'e4248068-1c1a-49e4-89fe-50d53f84268f';
    v_exists    boolean;
    v_runs_before   int;
    v_audit_before  int;
    v_runs_after    int;
    v_audit_after   int;
    v_is_active     boolean;
    v_auth_user     uuid;
BEGIN
    SELECT EXISTS (SELECT 1 FROM public.operator WHERE id = v_op) INTO v_exists;

    IF NOT v_exists THEN
        -- 新規DBへの通し適用時など、当該行が存在しない環境では何もしない。
        -- 本migrationは本番固有のデータ整理であり、存在しないことは異常ではない。
        RAISE NOTICE '075: seed-user operator % not present in this database; nothing to do', v_op;
        RETURN;
    END IF;

    -- 適用前の件数を保全する
    SELECT count(*) INTO v_runs_before  FROM public.run          WHERE finalized_by = v_op;
    SELECT count(*) INTO v_audit_before FROM public.audit_event  WHERE operator_id  = v_op;
    SELECT is_active, auth_user_id INTO v_is_active, v_auth_user
      FROM public.operator WHERE id = v_op;

    RAISE NOTICE '075 before: is_active=% auth_user_id=% finalized_runs=% audit_events=%',
        v_is_active, v_auth_user, v_runs_before, v_audit_before;

    -- operator ID で限定して無効化する
    UPDATE public.operator
       SET is_active = false
     WHERE id = v_op;

    -- 適用後の確認（件数が保持されていること）
    SELECT count(*) INTO v_runs_after  FROM public.run         WHERE finalized_by = v_op;
    SELECT count(*) INTO v_audit_after FROM public.audit_event WHERE operator_id  = v_op;

    IF v_runs_after IS DISTINCT FROM v_runs_before THEN
        RAISE EXCEPTION '075 failed: finalized run count changed (% -> %)', v_runs_before, v_runs_after;
    END IF;
    IF v_audit_after IS DISTINCT FROM v_audit_before THEN
        RAISE EXCEPTION '075 failed: audit_event count changed (% -> %)', v_audit_before, v_audit_after;
    END IF;

    SELECT is_active INTO v_is_active FROM public.operator WHERE id = v_op;
    IF v_is_active THEN
        RAISE EXCEPTION '075 failed: operator % is still active', v_op;
    END IF;

    -- operator 行自体は削除しない（証跡の参照先を保つため）
    IF NOT EXISTS (SELECT 1 FROM public.operator WHERE id = v_op) THEN
        RAISE EXCEPTION '075 failed: operator row must be retained, not deleted';
    END IF;

    RAISE NOTICE '075 after: is_active=false, finalized_runs=% (unchanged), audit_events=% (unchanged)',
        v_runs_after, v_audit_after;
END;
$apply$;
