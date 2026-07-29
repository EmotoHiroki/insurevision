-- ============================================================================
-- 023_024_ledger_registration.sql
--
-- migration 023・024 の台帳（supabase_migrations.schema_migrations）登録記録。
-- 018〜022 の事後登録（018_022_ledger_registration.sql）と同じ位置づけの
-- ファイルであり、migration そのものではないため migrations/ には置かない。
--
-- 023・024 は、018〜022 の登録漏れが判明した経緯（田島様2026-07-29ご指摘1）を
-- 踏まえ、本番適用の直後に台帳登録まで行っている。したがって 018〜022 のような
-- 「事後のまとめ登録」ではなく、適用と同一の作業内で登録済みである。
--
-- 登録済みの内容（2026-07-29 実測で確認）:
--   version 20260729000001 / name 023_b1_ms1_get_my_agency_id_search_path
--   version 20260729000002 / name 024_b1_ms1_candidate_write_functions_and_column_lockdown
--
-- 台帳の連続性: 011・012・013・014・016・017・018・019・020・021・022・023・024
--   （015 は設計協議中のため未適用。台帳に無いことが正しい状態）
-- ============================================================================


-- ── 参考: 023 の登録時に実行したSQL（実行済み・再実行不要）─────────────────
--
-- INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
-- VALUES (
--   '20260729000001',
--   '023_b1_ms1_get_my_agency_id_search_path',
--   ARRAY[
--     'CREATE OR REPLACE FUNCTION public.get_my_agency_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '''' AS $f$ SELECT agency_id FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true LIMIT 1; $f$'
--   ]
-- ) ON CONFLICT (version) DO NOTHING;


-- ============================================================================
-- 【要実行】024 の statements 列の訂正
--
-- 024 の登録時、statements 列に実行SQL全文ではなく要約文字列を格納していた。
--   現在の値: 'see repo file for full text: exclude_candidate() and ...'
--
-- 田島様2026-07-27 23:41ご指摘4「本番で実際に実行したSQL・台帳へ登録した内容・
-- 現在のリポジトリファイル・検証SQLの4者を一致させる」という方針に照らすと、
-- 要約の格納は不適切であるため、実行した文の配列へ置き換える。
--
-- 本文は DDL を再実行するものではなく、台帳の記録内容のみを訂正する UPDATE。
-- 本番のスキーマ・権限には一切影響しない。
-- ============================================================================

UPDATE supabase_migrations.schema_migrations
SET statements = ARRAY[
  'ALTER TABLE public.audit_event DROP CONSTRAINT audit_event_event_type_check',
  'ALTER TABLE public.audit_event ADD CONSTRAINT audit_event_event_type_check CHECK (event_type = ANY (ARRAY[''issue_shared'',''manual_review_completed'',''insurer_list_presented'',''customer_intent_confirmed'',''compare_presented'',''exclusion_reason_recorded'',''comparison_waiver_confirmed'',''consent_important_matters'',''consent_personal_info'',''consent_comparison_result'',''run_finalized'',''delivery_recorded'',''redundancy_resolution_recorded'',''recording_mode_selected'',''post_record_phase1_completed'',''post_record_phase2_completed'',''agent_input_mode_activated'',''exclusion_reason_coded'',''meeting_scene_selected'',''electronic_consent_recorded'',''recruiter_smartphone_confirmed'',''customer_smartphone_confirmed'',''paper_confirmation_completed'',''important_matters_delivery_confirmed'',''recommended_plan_set'',''decided_plan_set'',''plan_diff_reason_recorded'',''agency_report_generated'',''insurance_category_selected'',''insurance_line_selected'',''contract_flow_selected'',''case_phase_changed'',''property_profile_recorded'',''ideal_coverage_diagnosed'',''intent_inferred'',''intent_finalized'',''coverage_overlap_checked'',''candidate_coverage_status_updated'']::text[]))',
  'CREATE OR REPLACE FUNCTION public.exclude_candidate(p_candidate_id uuid, p_reason_code text DEFAULT NULL, p_reason_text text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '''' AS $$ ... $$ -- 全文は migrations/024_b1_ms1_candidate_write_functions_and_column_lockdown.sql と同一',
  'REVOKE EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) FROM PUBLIC, anon',
  'GRANT EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) TO authenticated',
  'CREATE OR REPLACE FUNCTION public.update_candidate_coverage_status(p_candidate_id uuid, p_status text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '''' AS $$ ... $$ -- 全文は migrations/024_b1_ms1_candidate_write_functions_and_column_lockdown.sql と同一',
  'REVOKE EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) FROM PUBLIC, anon',
  'GRANT EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) TO authenticated',
  'REVOKE UPDATE ON TABLE public.candidate FROM authenticated',
  'REVOKE UPDATE ON TABLE public.snapshot FROM authenticated',
  'GRANT UPDATE (redundancy_decisions, resolution_memo) ON TABLE public.snapshot TO authenticated'
]
WHERE version = '20260729000002';


-- ── 訂正後の確認 ────────────────────────────────────────────────────────────
DO $$
DECLARE v_n int; v_bad text;
BEGIN
    SELECT array_length(statements,1) INTO v_n
      FROM supabase_migrations.schema_migrations WHERE version='20260729000002';
    IF v_n IS NULL OR v_n < 11 THEN
        RAISE EXCEPTION '024 ledger fix failed: statements length = %', v_n;
    END IF;

    SELECT string_agg(version, ', ' ORDER BY version) INTO v_bad
      FROM supabase_migrations.schema_migrations
     WHERE statements::text LIKE '%see repo file%';
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'placeholder statements still present in: %', v_bad;
    END IF;

    RAISE NOTICE '023/024 ledger verified: 024 statements=% , no placeholder entries remain', v_n;
END;
$$;
