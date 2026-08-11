-- ============================================================================
-- 071_b1_ms1_suspension_audit_recording.sql
--
-- 田島様2026-08-10ご指摘②への対応。
--
-- 【ご指摘の内容】
--   保留・再開を audit_event へ記録し、次を追跡可能とすること。
--     保留前の run_status／保留種別／保留日時／保留メモ／
--     再開後の run_status／操作者／操作日時
--
-- 【本migrationで行うこと】
--   1. audit_event.event_type の CHECK 制約へ 'run_suspended'・'run_resumed' を
--      追加する（39種類 → 41種類）。従来の39種類には保留・再開に相当する値が
--      無く、記録しようとすると制約違反で失敗する状態であった。
--   2. 保留・再開を記録する専用のトリガー関数を新設し、run へ接続する。
--      記録は画面からの直接INSERTではなく、状態遷移が成立した後にDB側で行う。
--      関数は SECURITY DEFINER とし、所有者権限で audit_event へ記録する。
--   3. 上記2種別を enforce_audit_event_protected_types() の保護対象へ追加し、
--      authenticated による直接INSERTを拒否する（20種類 → 22種類）。
--      これにより「操作は行うが記録だけ省略する」「記録だけを偽造する」経路が
--      塞がれ、保留・再開の操作と監査記録が同一トランザクションで一体となる。
--
-- 【操作者の特定について】
--   operator_id は引数で受け取らず、auth.uid() から導出した有効な operator に
--   限定する（audit_event.operator_id は NOT NULL）。
--   操作者を特定できない接続からの保留・再開は、記録が残せないため
--   遷移そのものを拒否する。これは「記録の無い保留・再開を発生させない」ための
--   意図的な仕様である。
--
-- 既存migrationは編集していない。本ファイルのみを追加する。
-- ============================================================================

-- ── 1. CHECK制約へ保留・再開の種別を追加（39種類 -> 41種類） ────────────────
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
    'candidate_coverage_status_updated','candidate_added',
    'run_suspended','run_resumed'
]));


-- ── 2. 保留・再開の監査記録トリガー ────────────────────────────────────────
-- run_status が suspended へ入る／から出る遷移が成立した直後に記録する。
-- BEFORE トリガー（enforce_run_finalize_lockdown）で遷移が拒否された場合は
-- 本関数まで到達しないため、成立した操作のみが記録される。
CREATE OR REPLACE FUNCTION public.record_run_suspension_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_operator_id uuid;
    v_event_type  text;
    v_payload     jsonb;
BEGIN
    IF OLD.run_status IS NOT DISTINCT FROM NEW.run_status THEN
        RETURN NULL;
    END IF;

    IF NEW.run_status = 'suspended' THEN
        v_event_type := 'run_suspended';
        v_payload := jsonb_build_object(
            'previous_run_status', OLD.run_status,
            'new_run_status',      NEW.run_status,
            'suspension_type',     NEW.suspension_type,
            'pending_note',        NEW.pending_note,
            'suspended_at',        NEW.suspended_at
        );
    ELSIF OLD.run_status = 'suspended' THEN
        v_event_type := 'run_resumed';
        v_payload := jsonb_build_object(
            'previous_run_status', OLD.run_status,
            'new_run_status',      NEW.run_status,
            'suspension_type',     OLD.suspension_type,
            'pending_note',        OLD.pending_note,
            'suspended_at',        OLD.suspended_at
        );
    ELSE
        -- 保留・再開以外の遷移は本トリガーの対象外
        RETURN NULL;
    END IF;

    -- 操作者は呼出し元のセッションから導出する（引数を信用しない）
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION
          'run: suspend/resume requires an identifiable active operator so the change can be audited (run %)',
          NEW.id;
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (NEW.id, v_event_type, v_operator_id, v_payload);

    RETURN NULL;
END;
$function$;

-- トリガー関数の直接実行を禁じる（migration 062 と同じ扱い）
REVOKE EXECUTE ON FUNCTION public.record_run_suspension_audit() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_run_suspension_audit ON public.run;
CREATE TRIGGER trg_run_suspension_audit
    AFTER UPDATE OF run_status ON public.run
    FOR EACH ROW
    EXECUTE FUNCTION public.record_run_suspension_audit();


-- ── 3. 保留・再開の種別を保護対象へ追加（20種類 -> 22種類） ─────────────────
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
        'candidate_added',
        'run_suspended', 'run_resumed'
    ) THEN
        RAISE EXCEPTION 'audit_event: event_type "%" can only be recorded via its dedicated function, not by direct insert', NEW.event_type;
    END IF;
    RETURN NEW;
END;
$$;


-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE
    v_def text;
    v_src text;
BEGIN
    -- CHECK制約に2種別が追加されていること
    SELECT pg_get_constraintdef(oid) INTO v_def
      FROM pg_constraint
     WHERE conrelid = 'public.audit_event'::regclass
       AND conname  = 'audit_event_event_type_check';
    IF v_def IS NULL THEN
        RAISE EXCEPTION '071 failed: audit_event_event_type_check not found';
    END IF;
    IF v_def NOT LIKE '%run_suspended%' OR v_def NOT LIKE '%run_resumed%' THEN
        RAISE EXCEPTION '071 failed: the CHECK constraint does not permit run_suspended / run_resumed';
    END IF;
    -- 既存種別が失われていないこと（代表値で確認）
    IF v_def NOT LIKE '%run_finalized%' OR v_def NOT LIKE '%candidate_added%' THEN
        RAISE EXCEPTION '071 failed: an existing event_type was lost from the CHECK constraint';
    END IF;

    -- 監査トリガー関数が SECURITY DEFINER で作成されていること
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='record_run_suspension_audit';
    IF v_src IS NULL THEN
        RAISE EXCEPTION '071 failed: record_run_suspension_audit not found';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc
         WHERE pronamespace='public'::regnamespace
           AND proname='record_run_suspension_audit'
           AND prosecdef
           AND array_to_string(proconfig, ',') LIKE '%search_path=%'
    ) THEN
        RAISE EXCEPTION '071 failed: record_run_suspension_audit is not SECURITY DEFINER with a fixed search_path';
    END IF;
    IF v_src NOT LIKE '%auth.uid()%' THEN
        RAISE EXCEPTION '071 failed: the audit trigger does not derive the operator from auth.uid()';
    END IF;

    -- トリガーが run へ接続されていること
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
         WHERE NOT t.tgisinternal
           AND c.relname = 'run'
           AND t.tgname  = 'trg_run_suspension_audit'
    ) THEN
        RAISE EXCEPTION '071 failed: trg_run_suspension_audit is not attached to public.run';
    END IF;

    -- 保護対象へ2種別が追加されていること
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='enforce_audit_event_protected_types';
    IF v_src IS NULL THEN
        RAISE EXCEPTION '071 failed: enforce_audit_event_protected_types not found';
    END IF;
    IF v_src NOT LIKE '%run_suspended%' OR v_src NOT LIKE '%run_resumed%' THEN
        RAISE EXCEPTION '071 failed: run_suspended / run_resumed are not protected from direct insert';
    END IF;
    IF v_src NOT LIKE '%candidate_added%' OR v_src NOT LIKE '%run_finalized%' THEN
        RAISE EXCEPTION '071 failed: an existing protected event_type was lost';
    END IF;

    -- 保護トリガーが audit_event へ接続されたままであること
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
         WHERE NOT t.tgisinternal
           AND c.relname = 'audit_event'
           AND t.tgfoid = 'public.enforce_audit_event_protected_types'::regproc
    ) THEN
        RAISE EXCEPTION '071 failed: the audit_event protection trigger is no longer attached';
    END IF;

    RAISE NOTICE '071: suspend/resume are recorded into audit_event by the database and cannot be inserted directly';
END;
$selfcheck$;
