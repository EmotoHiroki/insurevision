-- ============================================================================
-- 051_b1_ms1_add_candidate_function_and_insert_lockdown.sql
--
-- 背景（田島様2026-08-04ご指摘4後半への対応）:
--
--   candidateの新規追加は、これまで`src/app/run/[id]/page.tsx`の
--   `handleAddCandidate`・`handleAddRecommended`が`.from('candidate')
--   .insert()`で直接行っていた。`authenticated`はcandidateテーブルへの
--   テーブル全体のINSERT権限を持ち、専任関数を経由しないため：
--     - 比較提示後（compare_presented_at設定後）に候補を追加しても、
--       提示済み状態が無効化されず、変更履歴（audit_event）も残らない。
--     - run行のロックを取らないため、finalize_runとの並行実行に対する
--       直列化が保証されない。
--
-- 【対応】
--   `add_candidate` SECURITY DEFINER関数を新設し、exclude_candidate・
--   update_candidate_coverage_statusと同じパターン（run行を先にロック、
--   agency照合、finalized/archived拒否、compare_presented_at無効化、
--   audit_event記録を同一トランザクションで実施）に統一する。
--   あわせて、authenticatedのcandidateへの直接INSERT権限を剥奪する。
-- ============================================================================

CREATE FUNCTION public.add_candidate(
    p_run_id uuid,
    p_insurer_name text DEFAULT '',
    p_product_name text DEFAULT NULL,
    p_annual_premium integer DEFAULT NULL,
    p_role text DEFAULT NULL
) RETURNS public.candidate
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id       uuid;
    v_run_agency        uuid;
    v_run_status        text;
    v_compare_presented timestamptz;
    v_next_slot         int;
    v_candidate         public.candidate;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'add_candidate: no active operator for the calling session';
    END IF;

    IF p_role IS NULL AND btrim(coalesce(p_insurer_name, '')) = '' THEN
        RAISE EXCEPTION 'add_candidate: insurer_name is required';
    END IF;

    -- runを先にロックしてから判定する（044・050で他関数に適用した順序と統一）
    SELECT agency_id, run_status, compare_presented_at
      INTO v_run_agency, v_run_status, v_compare_presented
      FROM public.run WHERE id = p_run_id FOR UPDATE;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'add_candidate: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'add_candidate: run does not belong to caller''s agency';
    END IF;
    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION 'add_candidate: run is %, candidates can no longer be added', v_run_status;
    END IF;

    SELECT coalesce(max(slot_no), 0) + 1 INTO v_next_slot
      FROM public.candidate WHERE run_id = p_run_id;

    INSERT INTO public.candidate (run_id, slot_no, insurer_name, product_name, annual_premium, role, status)
    VALUES (p_run_id, v_next_slot, coalesce(p_insurer_name, ''), p_product_name, p_annual_premium, p_role, 'active')
    RETURNING * INTO v_candidate;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'candidate_added', v_operator_id,
            jsonb_build_object('candidate_id', v_candidate.id, 'slot_no', v_next_slot, 'role', p_role));

    IF v_compare_presented IS NOT NULL THEN
        UPDATE public.run SET compare_presented_at = NULL WHERE id = p_run_id;
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'compare_presented', v_operator_id,
                jsonb_build_object(
                    'invalidated', true,
                    'invalidated_reason', 'candidate_added_after_presentation',
                    'candidate_id', v_candidate.id,
                    'previous_presented_at', v_compare_presented
                ));
    END IF;

    RETURN v_candidate;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.add_candidate(uuid, text, text, integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.add_candidate(uuid, text, text, integer, text) TO authenticated;

-- add_candidate経由のみとし、直接INSERTの経路を閉じる
REVOKE INSERT ON public.candidate FROM authenticated;


-- ── candidate_addedを保護対象イベントへ追加（既存パターンとの統一） ─────
CREATE OR REPLACE FUNCTION public.enforce_audit_event_protected_types()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
BEGIN
    IF current_user = 'authenticated' AND NEW.event_type IN (
        'run_finalized', 'consent_comparison_result',
        'recruiter_smartphone_confirmed', 'customer_smartphone_confirmed',
        'property_profile_recorded', 'candidate_coverage_status_updated',
        'exclusion_reason_recorded', 'exclusion_reason_coded',
        'redundancy_resolution_recorded', 'insurer_list_presented',
        'compare_presented',
        'recommended_plan_set', 'decided_plan_set', 'plan_diff_reason_recorded',
        'electronic_consent_recorded', 'paper_confirmation_completed',
        'important_matters_delivery_confirmed',
        'consent_important_matters', 'consent_personal_info',
        'candidate_added'
    ) THEN
        RAISE EXCEPTION 'audit_event: event_type "%" can only be recorded via its dedicated function, not by direct insert', NEW.event_type;
    END IF;
    RETURN NEW;
END;
$$;


-- ── audit_event.event_typeのCHECK制約に'candidate_added'を追加 ──────────
-- 上記のadd_candidate()内のINSERTが、既存のCHECK制約（許容値リスト）に
-- 'candidate_added'を含めていなかったため失敗することを本番適用直後の
-- 実機テストで検出した。トランザクション全体がロールバックされ、
-- candidate行も作成されずに終わることを確認した上で是正する。
ALTER TABLE public.audit_event DROP CONSTRAINT audit_event_event_type_check;
ALTER TABLE public.audit_event ADD CONSTRAINT audit_event_event_type_check
CHECK (event_type = ANY (ARRAY[
    'issue_shared','manual_review_completed','insurer_list_presented','customer_intent_confirmed',
    'compare_presented','exclusion_reason_recorded','comparison_waiver_confirmed','consent_important_matters',
    'consent_personal_info','consent_comparison_result','run_finalized','delivery_recorded',
    'redundancy_resolution_recorded','recording_mode_selected','post_record_phase1_completed',
    'post_record_phase2_completed','agent_input_mode_activated','exclusion_reason_coded','meeting_scene_selected',
    'electronic_consent_recorded','recruiter_smartphone_confirmed','customer_smartphone_confirmed',
    'paper_confirmation_completed','important_matters_delivery_confirmed','recommended_plan_set',
    'decided_plan_set','plan_diff_reason_recorded','agency_report_generated','insurance_category_selected',
    'insurance_line_selected','contract_flow_selected','case_phase_changed','property_profile_recorded',
    'ideal_coverage_diagnosed','intent_inferred','intent_finalized','coverage_overlap_checked',
    'candidate_coverage_status_updated','candidate_added'
]));
