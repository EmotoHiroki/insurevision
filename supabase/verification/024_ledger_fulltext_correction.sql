-- ============================================================================
-- 024 台帳 statements 列 訂正SQL（第2版・全文版）
--
-- 状態: 本番へ適用済み・実測確認済み（2026-07-31再確認: 台帳のstatements列を
-- 実測したところ、11文とも本SQLのとおりの全文で格納されており、省略記号を
-- 含まないことを確認した。以下は適用済みの記録であり、再実行は不要）。
--
-- 経緯:
--   第1版の訂正SQLでは、2つのCREATE FUNCTION文について本体を
--   `$$ ... $$` という省略形で格納していた。これは「要約文字列を格納していた」
--   という当初の不備と本質的に同じであり、田島様ご指摘4の「本番で実行したSQL・
--   台帳の内容・リポジトリファイル・検証SQLの4者を一致させる」を満たさない。
--
--   また第1版の自己検査は「配列長11以上」「特定の文字列を含まない」しか判定して
--   おらず、本体が省略されたままでも通過する弱い検査だった。本版では各文の長さと
--   省略記号の有無、および関数本体の要となる照合ロジックの有無まで判定する。
--
-- 本SQLは migrations/024_..._lockdown.sql の実DDL 11文をそのまま格納する
-- （同ファイルからプログラムで抽出。手書き転記はしていない）。
-- DDLの再実行は行わず、台帳の記録内容のみを更新する。
-- ============================================================================

UPDATE supabase_migrations.schema_migrations
SET statements = ARRAY[
  $led1$ALTER TABLE public.audit_event DROP CONSTRAINT audit_event_event_type_check$led1$,
  $led2$ALTER TABLE public.audit_event ADD CONSTRAINT audit_event_event_type_check
  CHECK (event_type = ANY (ARRAY[
    'issue_shared','manual_review_completed','insurer_list_presented','customer_intent_confirmed',
    'compare_presented','exclusion_reason_recorded','comparison_waiver_confirmed','consent_important_matters',
    'consent_personal_info','consent_comparison_result','run_finalized','delivery_recorded',
    'redundancy_resolution_recorded','recording_mode_selected','post_record_phase1_completed',
    'post_record_phase2_completed','agent_input_mode_activated','exclusion_reason_coded',
    'meeting_scene_selected','electronic_consent_recorded','recruiter_smartphone_confirmed',
    'customer_smartphone_confirmed','paper_confirmation_completed','important_matters_delivery_confirmed',
    'recommended_plan_set','decided_plan_set','plan_diff_reason_recorded','agency_report_generated',
    'insurance_category_selected','insurance_line_selected','contract_flow_selected','case_phase_changed',
    'property_profile_recorded','ideal_coverage_diagnosed','intent_inferred','intent_finalized',
    'coverage_overlap_checked','candidate_coverage_status_updated'
  ]::text[]))$led2$,
  $led3$CREATE OR REPLACE FUNCTION public.exclude_candidate(
    p_candidate_id uuid,
    p_reason_code text DEFAULT NULL,
    p_reason_text text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: no active operator for the calling session';
    END IF;

    SELECT r.agency_id INTO v_run_agency
      FROM public.candidate c
      JOIN public.run r ON r.id = c.run_id
     WHERE c.id = p_candidate_id;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: candidate % not found', p_candidate_id;
    END IF;

    IF v_run_agency <> (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'exclude_candidate: candidate does not belong to caller''s agency';
    END IF;

    IF p_reason_code = 'R-999' AND (p_reason_text IS NULL OR btrim(p_reason_text) = '') THEN
        RAISE EXCEPTION 'exclude_candidate: reason text is required when reason code is R-999';
    END IF;

    UPDATE public.candidate
       SET status = 'excluded',
           exclusion_reason_code = p_reason_code,
           excluded_reason = nullif(btrim(coalesce(p_reason_text,'')),''),
           excluded_by = v_operator_id,
           excluded_at = now()
     WHERE id = p_candidate_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    SELECT c.run_id, 'exclusion_reason_recorded', v_operator_id,
           jsonb_build_object('candidate_id', p_candidate_id, 'reason', p_reason_text)
      FROM public.candidate c WHERE c.id = p_candidate_id;

    IF p_reason_code IS NOT NULL THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        SELECT c.run_id, 'exclusion_reason_coded', v_operator_id,
               jsonb_build_object('candidate_id', p_candidate_id, 'code', p_reason_code, 'memo', p_reason_text)
          FROM public.candidate c WHERE c.id = p_candidate_id;
    END IF;
END;
$$$led3$,
  $led4$REVOKE EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) FROM PUBLIC, anon$led4$,
  $led5$GRANT  EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) TO authenticated$led5$,
  $led6$CREATE OR REPLACE FUNCTION public.update_candidate_coverage_status(
    p_candidate_id uuid,
    p_status text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_id      uuid;
    v_run_agency  uuid;
BEGIN
    IF p_status NOT IN ('full','partial','none') THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: invalid status %', p_status;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: no active operator for the calling session';
    END IF;

    SELECT c.run_id, r.agency_id INTO v_run_id, v_run_agency
      FROM public.candidate c
      JOIN public.run r ON r.id = c.run_id
     WHERE c.id = p_candidate_id;

    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate % not found', p_candidate_id;
    END IF;

    IF v_run_agency <> (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate does not belong to caller''s agency';
    END IF;

    UPDATE public.candidate SET coverage_status = p_status WHERE id = p_candidate_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'candidate_coverage_status_updated', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'status', p_status));
END;
$$$led6$,
  $led7$REVOKE EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) FROM PUBLIC, anon$led7$,
  $led8$GRANT  EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) TO authenticated$led8$,
  $led9$REVOKE UPDATE ON TABLE public.candidate FROM authenticated$led9$,
  $led10$REVOKE UPDATE ON TABLE public.snapshot FROM authenticated$led10$,
  $led11$GRANT UPDATE (redundancy_decisions, resolution_memo) ON TABLE public.snapshot TO authenticated$led11$
]
WHERE version = '20260729000002';


-- ── 自己検査（第1版より厳格化）────────────────────────────────────────────
DO $verify$
DECLARE
    v_cnt      int;
    v_ellipsis text;
    v_excl_len int;
    v_upd_len  int;
    v_missing  text;
BEGIN
    SELECT array_length(statements,1) INTO v_cnt
      FROM supabase_migrations.schema_migrations WHERE version='20260729000002';
    IF v_cnt <> 11 THEN
        RAISE EXCEPTION '024 ledger: expected 11 statements, found %', v_cnt;
    END IF;

    SELECT string_agg(format('#%s', i), ', ') INTO v_ellipsis
      FROM supabase_migrations.schema_migrations sm,
           LATERAL unnest(sm.statements) WITH ORDINALITY AS t(stmt, i)
     WHERE sm.version='20260729000002'
       AND (stmt LIKE '%$$ ... $$%' OR stmt LIKE '%see repo file%');
    IF v_ellipsis IS NOT NULL THEN
        RAISE EXCEPTION '024 ledger: abbreviated statements remain at %', v_ellipsis;
    END IF;

    SELECT max(length(stmt)) INTO v_excl_len
      FROM supabase_migrations.schema_migrations sm, LATERAL unnest(sm.statements) AS stmt
     WHERE sm.version='20260729000002' AND stmt LIKE '%FUNCTION public.exclude_candidate%';
    SELECT max(length(stmt)) INTO v_upd_len
      FROM supabase_migrations.schema_migrations sm, LATERAL unnest(sm.statements) AS stmt
     WHERE sm.version='20260729000002' AND stmt LIKE '%FUNCTION public.update_candidate_coverage_status%';

    IF v_excl_len IS NULL OR v_excl_len < 1500 THEN
        RAISE EXCEPTION '024 ledger: exclude_candidate body looks truncated (len=%)', v_excl_len;
    END IF;
    IF v_upd_len IS NULL OR v_upd_len < 1000 THEN
        RAISE EXCEPTION '024 ledger: update_candidate_coverage_status body looks truncated (len=%)', v_upd_len;
    END IF;

    SELECT string_agg(k, ', ') INTO v_missing
      FROM unnest(ARRAY['auth.uid()', 'is_active = true', 'RAISE EXCEPTION']) AS k
     WHERE NOT EXISTS (
        SELECT 1 FROM supabase_migrations.schema_migrations sm, LATERAL unnest(sm.statements) AS stmt
         WHERE sm.version='20260729000002' AND stmt LIKE '%'||k||'%');
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION '024 ledger: function body missing expected logic: %', v_missing;
    END IF;

    RAISE NOTICE '024 ledger verified: 11 statements, no abbreviation, exclude_candidate=% chars, update_candidate_coverage_status=% chars', v_excl_len, v_upd_len;
END;
$verify$;
