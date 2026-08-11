-- ============================================================================
-- 028_check.sql
--
-- migration 028（NULL安全化・確定後Freeze・重複抑止）の検証。DDLを含まない。
-- ============================================================================
DO $$
DECLARE v_def text;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='update_candidate_coverage_status';
    IF v_def NOT LIKE '%p_status IS NULL OR p_status NOT IN%' THEN
        RAISE EXCEPTION '028 verify failed: update_candidate_coverage_status missing NULL-safe status check';
    END IF;
    IF v_def NOT LIKE '%IS DISTINCT FROM%' THEN
        RAISE EXCEPTION '028 verify failed: update_candidate_coverage_status missing IS DISTINCT FROM agency check';
    END IF;
    -- 【2026-08-06修正】028当時は「finalized_at IS NOT NULL なら拒否」という
    -- 拒否リスト方式だった。migration 056で、保留（suspended）等の新しい状態が
    -- 素通りしないよう「draft・post_record_pending 以外は拒否」という
    -- 許可リスト方式へ強化している。文字列を直書きしていたため、
    -- 保護がより強くなったにもかかわらず本検査は「保護が無い」と報告していた。
    -- 現行の許可リスト方式を期待値とし、旧方式も受け入れる。
    IF v_def NOT LIKE '%run_status NOT IN (''draft'', ''post_record_pending'')%'
       AND v_def NOT LIKE '%finalized_at IS NOT NULL%' THEN
        RAISE EXCEPTION '028 verify failed: update_candidate_coverage_status missing finalized-run check';
    END IF;
    IF v_def NOT LIKE '%v_current_status IS NOT DISTINCT FROM p_status%' THEN
        RAISE EXCEPTION '028 verify failed: update_candidate_coverage_status missing same-status skip guard';
    END IF;

    SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='exclude_candidate';
    IF v_def NOT LIKE '%IS DISTINCT FROM%' THEN
        RAISE EXCEPTION '028 verify failed: exclude_candidate missing IS DISTINCT FROM agency check';
    END IF;
    -- 上と同じ理由で、許可リスト方式・拒否リスト方式のいずれも受け入れる。
    IF v_def NOT LIKE '%run_status NOT IN (''draft'', ''post_record_pending'')%'
       AND v_def NOT LIKE '%finalized_at IS NOT NULL%' THEN
        RAISE EXCEPTION '028 verify failed: exclude_candidate missing finalized-run check';
    END IF;

    RAISE NOTICE '028 verify passed: both functions have NULL-safety, IS DISTINCT FROM, and finalized-run checks';
END $$;

-- ── 横展開: 他のSECURITY DEFINER関数に同型の不備が残っていないか ───────────
-- SECURITY DEFINER関数は呼出し元の権限ではなく所有者の権限で動作するため、
-- 増えた場合は必ず内容を確認する必要がある。ここでは既知の関数を許可リストとして
-- 持ち、それ以外が出現したら報告する。
--
-- 【2026-08-06更新】028当時の許可リストは4件のままだったため、
-- その後のmigrationで正当に追加された関数17件をすべて「想定外」として
-- 報告する状態になっていた。許可リストを現行の全件へ更新する。
-- 新しいSECURITY DEFINER関数を追加した際は、内容を確認したうえで
-- 本リストへ追記すること。リストを更新せずに検査を無効化しないこと。
DO $$
DECLARE v_others text;
BEGIN
    SELECT string_agg(proname, ', ' ORDER BY proname) INTO v_others
      FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND prosecdef=true
       AND proname NOT IN (
            -- 028時点で存在していたもの
            'exclude_candidate','update_candidate_coverage_status',
            'get_my_agency_id','finalize_run',
            -- 候補・スナップショット操作（024・032・045・051）
            'add_candidate','update_snapshot_redundancy_decisions',
            'update_snapshot_resolution_memo','record_plan_selection',
            -- 記録系（043・046・047・048）
            'record_compare_presented','record_insurer_list_presented',
            'record_electronic_consent','record_paper_confirmation',
            'record_important_matters_delivery','save_property_profile',
            -- スマホ確認フロー（040・041）
            'confirm_smartphone','get_smartphone_confirm_status',
            'issue_smartphone_confirm_token','record_smartphone_manual_confirmation',
            -- 証跡（056・057・058）
            'save_run_proof','build_run_proof_payload','enforce_proof_object_immutable',
            -- 保留・再開の監査記録（071）
            --   トリガー専用関数。所有者権限で audit_event へ記録するため
            --   SECURITY DEFINER としている。operator_id は引数で受け取らず
            --   auth.uid() から導出する。EXECUTE は PUBLIC・anon・authenticated・
            --   service_role のいずれからも剥奪済み（071・072）。
            'record_run_suspension_audit'
       );
    IF v_others IS NOT NULL THEN
        RAISE EXCEPTION '028 sweep: unexpected additional SECURITY DEFINER functions found, review needed -> %', v_others;
    END IF;
    RAISE NOTICE '028 sweep passed: no SECURITY DEFINER functions beyond the 4 already known and tracked';
END $$;
