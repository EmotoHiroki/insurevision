-- ============================================================================
-- 024_b1_ms1_candidate_write_functions_and_column_lockdown.sql
--
-- 状態: 本番適用済み
--
-- 背景（田島様ご指摘「snapshot.unresolved_items等の確定条件列と、candidateの
-- 判定・状態関連列については、agencyスコープ化だけでは同一代理店内からの
-- 直接書換えが残ります。直接UPDATEの制限と照合付き書込経路を、第3段階の
-- 恒久是正に含めてください」への対応）。
--
-- アプリコードを確認した結果:
--   - `snapshot.unresolved_items` は `run/new` でのスナップショット作成時に
--     一度だけ書き込まれ、その後の更新経路はアプリ内に一切存在しない。
--   - `snapshot.redundancy_decisions`・`resolution_memo` は現行アプリで
--     直接UPDATEされている、確定条件そのものではない実利用中の列。
--   - `candidate.status`・`excluded_reason`・`exclusion_reason_code`・
--     `excluded_by`・`excluded_at`・`coverage_status` は
--     `handleExcludeCandidate`・`handleUpdateCoverageStatus`
--     （src/app/run/[id]/page.tsx）から直接UPDATEされていた。
--   - candidateには上記以外の直接UPDATE経路は存在しない。
--
-- 重要な実装上の訂正（適用時に判明）:
--   当初 `REVOKE UPDATE (列名, ...) ON TABLE ... FROM authenticated` の形で
--   列単位のみ剥奪しようとしたが、実測の結果これは無効だった。
--   authenticated は snapshot・candidate 双方にテーブル全体のUPDATE権限を
--   （USING(true)時代からのGRANTとして）保持したままであり、PostgreSQLの
--   権限は加算的であるため、テーブル全体のGRANTが残っている限り列単位の
--   REVOKEは上書きされず、直接UPDATEが成立し続けることを実測で確認した
--   （実際に candidate.status・snapshot.unresolved_items への直接PATCHが
--   204で成立し、値が変更されることを確認）。
--   正しい手順は、テーブル全体のUPDATE権限を先に剥奪したうえで、
--   必要な列のみ列単位でGRANTし直すことである。本ファイルは訂正後の
--   正しい手順を記載している。
--
-- 対応:
--   1. candidate: テーブル全体のUPDATE権限を剥奪。直接UPDATEの経路を
--      全廃し、以下の2関数経由に統一する。
--   2. snapshot: テーブル全体のUPDATE権限を剥奪したうえで、
--      redundancy_decisions・resolution_memo のみ列単位で再GRANTする。
--      unresolved_items は再GRANTしない（直接UPDATE経路が存在しないため）。
--   3. アプリコード（src/app/run/[id]/page.tsx）を、直接UPDATEから
--      該当関数の呼出しへ変更（同一コミットに含む）。
-- ============================================================================

-- ── 0. audit_event.event_type のCHECK制約に新規イベント種別を追加 ─────────
ALTER TABLE public.audit_event DROP CONSTRAINT audit_event_event_type_check;
ALTER TABLE public.audit_event ADD CONSTRAINT audit_event_event_type_check
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
  ]::text[]));

-- ── 1. candidateの除外処理・補償状況更新を照合付き関数に集約 ──────────────
CREATE OR REPLACE FUNCTION public.exclude_candidate(
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
$$;

REVOKE EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_candidate_coverage_status(
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
$$;

REVOKE EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) TO authenticated;

-- ── 2. candidate: テーブル全体のUPDATEを剥奪（直接UPDATE経路を全廃） ──────
REVOKE UPDATE ON TABLE public.candidate FROM authenticated;

-- ── 3. snapshot: テーブル全体のUPDATEを剥奪し、実利用中の2列のみ再GRANT ──
-- unresolved_items は意図的に再GRANTしない（直接更新経路がアプリに存在しないため）。
REVOKE UPDATE ON TABLE public.snapshot FROM authenticated;
GRANT UPDATE (redundancy_decisions, resolution_memo) ON TABLE public.snapshot TO authenticated;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE v_bad text;
BEGIN
    IF has_table_privilege('authenticated','public.candidate','UPDATE') THEN
        RAISE EXCEPTION '024 self-check failed: authenticated still has table-wide UPDATE on candidate';
    END IF;
    IF has_table_privilege('authenticated','public.snapshot','UPDATE') THEN
        RAISE EXCEPTION '024 self-check failed: authenticated still has table-wide UPDATE on snapshot';
    END IF;
    IF has_column_privilege('authenticated','public.snapshot','unresolved_items','UPDATE') THEN
        RAISE EXCEPTION '024 self-check failed: authenticated still has UPDATE on snapshot.unresolved_items';
    END IF;
    IF NOT has_column_privilege('authenticated','public.snapshot','redundancy_decisions','UPDATE') THEN
        RAISE EXCEPTION '024 self-check failed: authenticated lost UPDATE on snapshot.redundancy_decisions';
    END IF;
    IF NOT has_column_privilege('authenticated','public.snapshot','resolution_memo','UPDATE') THEN
        RAISE EXCEPTION '024 self-check failed: authenticated lost UPDATE on snapshot.resolution_memo';
    END IF;

    IF NOT has_function_privilege('authenticated','public.exclude_candidate(uuid,text,text)','EXECUTE') THEN
        RAISE EXCEPTION '024 self-check failed: authenticated missing EXECUTE on exclude_candidate';
    END IF;
    IF has_function_privilege('anon','public.exclude_candidate(uuid,text,text)','EXECUTE') THEN
        RAISE EXCEPTION '024 self-check failed: anon has EXECUTE on exclude_candidate';
    END IF;
    IF NOT has_function_privilege('authenticated','public.update_candidate_coverage_status(uuid,text)','EXECUTE') THEN
        RAISE EXCEPTION '024 self-check failed: authenticated missing EXECUTE on update_candidate_coverage_status';
    END IF;
    IF has_function_privilege('anon','public.update_candidate_coverage_status(uuid,text)','EXECUTE') THEN
        RAISE EXCEPTION '024 self-check failed: anon has EXECUTE on update_candidate_coverage_status';
    END IF;

    RAISE NOTICE '024 self-check passed';
END;
$$;
