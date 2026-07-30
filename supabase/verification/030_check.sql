-- ============================================================================
-- 030_check.sql
--
-- migration 030（finalize_run 第3段階恒久是正）の検証。DDLを含まない。
--
-- 田島様への報告で使用した実測（実JWT・実Data API経由）は、本ファイルでは
-- 再現できない（auth.uid()はPostgRESTのリクエスト単位のJWTから解決される
-- ため、DB接続内のSQL実行だけでは呼出者コンテキストを再現できない）。
-- 実測の記録は別紙「b1-MS1 第3段階 finalize_run恒久是正 実測証跡」を参照。
--
-- 本ファイルでは、カタログレベルで確認できる不変条件のみを検査する。
-- ============================================================================

DO $$
DECLARE
    v_count      int;
    v_args       text;
    v_def        text;
BEGIN
    -- 旧シグネチャ（p_operator_id を含む5引数版）が存在しないこと
    SELECT count(*) INTO v_count
      FROM pg_proc WHERE proname='finalize_run'
       AND pg_get_function_identity_arguments(oid) LIKE '%p_operator_id%';
    IF v_count <> 0 THEN
        RAISE EXCEPTION '030 verify failed: old finalize_run signature with p_operator_id still exists';
    END IF;

    -- finalize_run はちょうど1件のみ存在すること（オーバーロード残存なし）
    SELECT count(*) INTO v_count FROM pg_proc WHERE proname='finalize_run';
    IF v_count <> 1 THEN
        RAISE EXCEPTION '030 verify failed: expected exactly 1 finalize_run overload, found %', v_count;
    END IF;

    SELECT pg_get_function_identity_arguments(oid) INTO v_args
      FROM pg_proc WHERE proname='finalize_run';
    IF v_args <> 'p_run_id uuid, p_pdf_object_key text, p_pdf_sha256 text, p_consent_comparison_result boolean' THEN
        RAISE EXCEPTION '030 verify failed: unexpected finalize_run signature -> %', v_args;
    END IF;

    -- EXECUTE権限: PUBLIC/anonなし、authenticatedのみ
    IF has_function_privilege('public','public.finalize_run(uuid,text,text,boolean)','EXECUTE')
    OR has_function_privilege('anon','public.finalize_run(uuid,text,text,boolean)','EXECUTE') THEN
        RAISE EXCEPTION '030 verify failed: PUBLIC or anon still has EXECUTE on finalize_run';
    END IF;
    IF NOT has_function_privilege('authenticated','public.finalize_run(uuid,text,text,boolean)','EXECUTE') THEN
        RAISE EXCEPTION '030 verify failed: authenticated lost EXECUTE on finalize_run (would break the app)';
    END IF;

    -- search_pathが空文字列であること
    SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='finalize_run';
    IF v_def NOT LIKE '%SET search_path TO ''''%' THEN
        RAISE EXCEPTION '030 verify failed: finalize_run does not have empty search_path';
    END IF;

    -- 呼出者照合・agency照合・確定条件の各ロジックが本体に含まれること
    IF v_def NOT LIKE '%auth.uid()%' THEN
        RAISE EXCEPTION '030 verify failed: finalize_run does not derive caller from auth.uid()';
    END IF;
    IF v_def NOT LIKE '%does not belong to caller%' THEN
        RAISE EXCEPTION '030 verify failed: finalize_run missing agency check';
    END IF;
    IF v_def NOT LIKE '%unresolved_items remain%' THEN
        RAISE EXCEPTION '030 verify failed: finalize_run missing unresolved_items check';
    END IF;
    IF v_def NOT LIKE '%insurer_list_presented not recorded%' THEN
        RAISE EXCEPTION '030 verify failed: finalize_run missing insurer_list_presented check';
    END IF;
    IF v_def NOT LIKE '%important_matters_delivered not confirmed%' THEN
        RAISE EXCEPTION '030 verify failed: finalize_run missing important_matters_delivered check';
    END IF;
    IF v_def NOT LIKE '%''draft'', ''post_record_pending''%' THEN
        RAISE EXCEPTION '030 verify failed: finalize_run does not accept post_record_pending (G-21 fix missing)';
    END IF;

    RAISE NOTICE '030 verify passed: single 4-arg finalize_run, correct grants, empty search_path, all business-rule gates present';
END $$;

-- ============================================================================
-- 実測記録（2026-07-30、実JWT・実Data API経由。ここには再掲のみ。実行はしない）
--
-- 対象: agency A のテスト run（11111111-1111-1111-1111-111111111111）
--
-- 1. 他agency（00000000）の active operator → 拒否
--    "finalize_run: run does not belong to caller's agency" (HTTP 400)
-- 2. operatorに紐づかない実JWT（is_active検査以前にoperator自体が存在しない）→ 拒否
--    "finalize_run: no active operator for the calling session" (HTTP 400)
-- 3. 正しいagencyのactive operatorだが insurer_list_presented 未記録 → 拒否
--    "finalize_run: insurer_list_presented not recorded" (HTTP 400)
-- 4. insurer_list_presented記録後、meeting_scene設定・important_matters_delivered=false → 拒否
--    "finalize_run: important_matters_delivered not confirmed" (HTTP 400)
-- 5. snapshot.unresolved_items が非空 → 拒否
--    "finalize_run: unresolved_items remain (1 items)" (HTTP 400)
-- 6. 旧5引数シグネチャ（p_operator_id含む）での呼出し → 関数が存在せず拒否
--    PGRST202 "Could not find the function ..." (HTTP 404)
-- 7. すべての条件を満たした状態での呼出し → 成功 (HTTP 204)
--    run.finalized_by が実際の呼出者（実JWTのauth.uid()から解決したoperator.id）と
--    一致することを確認。引数でoperator_idを渡していないにもかかわらず、
--    正しい呼出者が記録された。
-- 8. 確定済みrunへの再度の呼出し → 拒否
--    "finalize_run: run ... not found or not in draft status" (HTTP 400)
--
-- テスト後、対象run・snapshotは元の状態（run_status='draft'、finalized_at/by=NULL、
-- important_matters_delivered=false、unresolved_items=[]）へ復元し、テスト中に
-- 追加したaudit_event（insurer_list_presented・run_finalized）も削除済み。
-- ============================================================================
