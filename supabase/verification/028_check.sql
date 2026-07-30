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
    IF v_def NOT LIKE '%finalized_at IS NOT NULL%' THEN
        RAISE EXCEPTION '028 verify failed: update_candidate_coverage_status missing finalized-run check';
    END IF;
    IF v_def NOT LIKE '%v_current_status IS NOT DISTINCT FROM p_status%' THEN
        RAISE EXCEPTION '028 verify failed: update_candidate_coverage_status missing same-status skip guard';
    END IF;

    SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='exclude_candidate';
    IF v_def NOT LIKE '%IS DISTINCT FROM%' THEN
        RAISE EXCEPTION '028 verify failed: exclude_candidate missing IS DISTINCT FROM agency check';
    END IF;
    IF v_def NOT LIKE '%finalized_at IS NOT NULL%' THEN
        RAISE EXCEPTION '028 verify failed: exclude_candidate missing finalized-run check';
    END IF;

    RAISE NOTICE '028 verify passed: both functions have NULL-safety, IS DISTINCT FROM, and finalized-run checks';
END $$;

-- ── 横展開: 他のSECURITY DEFINER関数に同型の不備が残っていないか ───────────
-- get_my_agency_id・exclude_candidate・update_candidate_coverage_status以外の
-- SECURITY DEFINER関数を全件列挙する。ここに finalize_run 以外が出現しない
-- ことを確認する（finalize_runは既知の課題としてStage 3で別途対応）。
DO $$
DECLARE v_others text;
BEGIN
    SELECT string_agg(proname, ', ') INTO v_others
      FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND prosecdef=true
       AND proname NOT IN ('exclude_candidate','update_candidate_coverage_status','get_my_agency_id','finalize_run');
    IF v_others IS NOT NULL THEN
        RAISE EXCEPTION '028 sweep: unexpected additional SECURITY DEFINER functions found, review needed -> %', v_others;
    END IF;
    RAISE NOTICE '028 sweep passed: no SECURITY DEFINER functions beyond the 4 already known and tracked';
END $$;
