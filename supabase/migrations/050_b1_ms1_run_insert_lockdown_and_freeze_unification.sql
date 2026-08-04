-- ============================================================================
-- 050_b1_ms1_run_insert_lockdown_and_freeze_unification.sql
--
-- 背景（田島様2026-08-04ご指摘1〜4への対応）:
--
--   1. runへの直接INSERT
--      `enforce_run_finalize_lockdown`はBEFORE UPDATEのみに接続されており、
--      INSERTには一切適用されていなかった。`authenticated`はrunテーブルへの
--      テーブル全体のINSERT権限を持ち、RLSの`run_insert_own_agency`は
--      `agency_id`の一致のみを検査する。実機検証で、run_status='finalized'・
--      finalized_at・finalized_by・pdf_sha256を最初から設定した新規行を
--      直接POSTで作成できること（finalize_run()を一切経由しない）を確認した。
--
--   2. finalize_runのFail-Closed（一部）
--      `important_matters_delivered`の検査は`meeting_scene IS NOT NULL`の
--      場合のみ実行されており、meeting_sceneがNULLだと検査自体がスキップ
--      される。同様に`recording_mode = 'post_record'`の場合のみ
--      post_record完了検査が実行され、recording_modeがNULLだと確定できて
--      しまう。田島様のご判断により、meeting_sceneとrecording_modeを
--      確定時必須とする。
--
--   3. 確定後Freezeの残穴と状態基準の不統一
--      a) `enforce_parent_run_not_finalized`はNEW.run_idのみを検査する。
--         intent_confirmation・csv_import_sessionはauthenticatedに
--         run_id列のUPDATE権限が残っており、RLSも新旧run_idの代理店一致
--         のみを検査するため、確定済みrunの子行を別のdraft run側へ
--         run_idごと付け替えるUPDATEが、旧親runの状態を検査されずに
--         通ってしまう。田島様のご提案どおり、run_idの変更自体を禁止する。
--      b) save_property_profile・record_compare_presented・
--         record_insurer_list_presentedは、いずれもrun_status='finalized'
--         のみを拒否しており、'archived'を拒否していない。これらは
--         SECURITY DEFINER関数であり、関数内から実行されるUPDATE/INSERTは
--         current_user=関数所有者（postgres）で実行されるため、
--         `current_user='authenticated'`の場合にのみ主要判定を行う
--         保護トリガー側の判定はそもそも働かない。関数内の明示的な状態
--         検査が実質的な唯一の門であり、そこにarchivedが抜けていた。
--
--   4. candidate状態遷移の並行制御（一部）
--      exclude_candidate・update_candidate_coverage_statusは
--      `FOR UPDATE OF c`でcandidate行のみをロックし、親runを無ロックで
--      読んでいる。finalize_runは`run`行を`FOR UPDATE`でロックするが、
--      ロック対象が異なるため、確定処理とこれら2関数の並行実行に対して
--      直列化が機能しない。044で他5関数に適用した「runを先にロックして
--      から判定する」順序を、この2関数にも適用する。
--
-- 【対応】
--   1. enforce_run_finalize_lockdownをBEFORE INSERT OR UPDATEへ拡張し、
--      INSERT時は「draft状態・確定関連列すべて未設定」以外を拒否する。
--   2. finalize_runにmeeting_scene・recording_modeのNOT NULL検査を追加。
--   3a. enforce_parent_run_not_finalizedで、run_id自体の変更を禁止する。
--   3b. save_property_profile・record_compare_presented・
--       record_insurer_list_presentedの状態検査に'archived'を追加。
--   4. exclude_candidate・update_candidate_coverage_statusで、run行を
--      先にFOR UPDATEでロックしてからcandidate行を読む順序へ変更。
-- ============================================================================

-- ── 1. run: BEFORE INSERT OR UPDATE へ拡張 ──────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
    v_new_normalized public.run;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF current_user = 'authenticated' THEN
            IF NEW.run_status IS DISTINCT FROM 'draft' THEN
                RAISE EXCEPTION 'run: new rows must be created with run_status=''draft'' (attempted %)', NEW.run_status;
            END IF;
            IF NEW.finalized_at IS NOT NULL OR NEW.finalized_by IS NOT NULL
               OR NEW.pdf_object_key IS NOT NULL OR NEW.pdf_sha256 IS NOT NULL
               OR (NEW.export_status IS NOT NULL AND NEW.export_status <> 'pending')
            THEN
                RAISE EXCEPTION 'run: finalize-owned fields cannot be set on insert, only via finalize_run()';
            END IF;
            IF NEW.compare_presented_at IS NOT NULL THEN
                RAISE EXCEPTION 'run: compare_presented_at cannot be set on insert, only via record_compare_presented()';
            END IF;
            IF NEW.recruiter_smartphone_confirmed_at IS NOT NULL
               OR NEW.customer_smartphone_confirmed_at IS NOT NULL
            THEN
                RAISE EXCEPTION 'run: smartphone confirmation fields cannot be set on insert';
            END IF;
            IF NEW.recommended_candidate_id IS NOT NULL OR NEW.decided_candidate_id IS NOT NULL
               OR NEW.plan_diff_reason IS NOT NULL OR NEW.plan_diff_reason_recorded_at IS NOT NULL
            THEN
                RAISE EXCEPTION 'run: plan selection fields cannot be set on insert';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    -- TG_OP = 'UPDATE'（既存ロジック。046・047から変更なし）
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized'
       AND NEW.run_status IS DISTINCT FROM 'archived'
    THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    IF OLD.run_status = 'archived' AND NEW.run_status IS DISTINCT FROM 'archived' THEN
        RAISE EXCEPTION 'run: cannot transition out of archived state (run %)', OLD.id;
    END IF;

    IF current_user = 'authenticated' THEN
        IF OLD.run_status = 'finalized' THEN
            IF NEW.run_status = 'archived' THEN
                v_new_normalized := NEW;
                v_new_normalized.run_status := OLD.run_status;
                v_new_normalized.updated_at := OLD.updated_at;
                IF v_new_normalized IS DISTINCT FROM OLD THEN
                    RAISE EXCEPTION 'run: only run_status may change when archiving a finalized run (run %)', OLD.id;
                END IF;
                RETURN NEW;
            END IF;
            RAISE EXCEPTION 'run: row is already finalized, no further direct modification permitted (run %)', OLD.id;
        END IF;

        IF OLD.run_status = 'archived' THEN
            RAISE EXCEPTION 'run: row is archived, no further direct modification permitted (run %)', OLD.id;
        END IF;

        IF NEW.run_status = 'finalized' THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
        END IF;

        IF NEW.finalized_at   IS DISTINCT FROM OLD.finalized_at
           OR NEW.finalized_by   IS DISTINCT FROM OLD.finalized_by
           OR NEW.pdf_object_key IS DISTINCT FROM OLD.pdf_object_key
           OR NEW.pdf_sha256     IS DISTINCT FROM OLD.pdf_sha256
           OR NEW.export_status  IS DISTINCT FROM OLD.export_status
        THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
        END IF;

        IF NEW.compare_presented_at IS DISTINCT FROM OLD.compare_presented_at THEN
            RAISE EXCEPTION 'run: compare_presented_at can only be modified via record_compare_presented() (run %)', OLD.id;
        END IF;

        IF NEW.recruiter_smartphone_confirmed_at IS DISTINCT FROM OLD.recruiter_smartphone_confirmed_at
           OR NEW.customer_smartphone_confirmed_at IS DISTINCT FROM OLD.customer_smartphone_confirmed_at
           OR NEW.smartphone_conf_status IS DISTINCT FROM OLD.smartphone_conf_status
        THEN
            RAISE EXCEPTION 'run: smartphone confirmation fields can only be modified via confirm_smartphone() or record_smartphone_manual_confirmation() (run %)', OLD.id;
        END IF;

        IF NEW.recommended_candidate_id IS DISTINCT FROM OLD.recommended_candidate_id
           OR NEW.decided_candidate_id IS DISTINCT FROM OLD.decided_candidate_id
           OR NEW.plan_diff_reason IS DISTINCT FROM OLD.plan_diff_reason
           OR NEW.plan_diff_reason_recorded_at IS DISTINCT FROM OLD.plan_diff_reason_recorded_at
        THEN
            RAISE EXCEPTION 'run: plan selection fields can only be modified via record_plan_selection() (run %)', OLD.id;
        END IF;

        IF NEW.electronic_consent_status      IS DISTINCT FROM OLD.electronic_consent_status
           OR NEW.electronic_consent_method    IS DISTINCT FROM OLD.electronic_consent_method
           OR NEW.electronic_consent_confirmed_at IS DISTINCT FROM OLD.electronic_consent_confirmed_at
           OR NEW.electronic_consent_operator_id  IS DISTINCT FROM OLD.electronic_consent_operator_id
        THEN
            RAISE EXCEPTION 'run: electronic consent fields can only be modified via record_electronic_consent() (run %)', OLD.id;
        END IF;

        IF NEW.paper_confirmation_status IS DISTINCT FROM OLD.paper_confirmation_status
           OR NEW.paper_confirmation_completed_at IS DISTINCT FROM OLD.paper_confirmation_completed_at
        THEN
            RAISE EXCEPTION 'run: paper confirmation fields can only be modified via record_paper_confirmation() (run %)', OLD.id;
        END IF;

        IF NEW.important_matters_delivered IS DISTINCT FROM OLD.important_matters_delivered
           OR NEW.important_matters_delivered_at IS DISTINCT FROM OLD.important_matters_delivered_at
           OR NEW.important_matters_delivery_method IS DISTINCT FROM OLD.important_matters_delivery_method
        THEN
            RAISE EXCEPTION 'run: important matters delivery fields can only be modified via record_important_matters_delivery() (run %)', OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_run_finalize_lockdown ON public.run;
CREATE TRIGGER trg_run_finalize_lockdown
    BEFORE INSERT OR UPDATE ON public.run
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_run_finalize_lockdown();


-- ── 2. finalize_run: meeting_scene・recording_modeを確定時必須化 ────────
CREATE OR REPLACE FUNCTION public.finalize_run(
    p_run_id uuid,
    p_pdf_object_key text,
    p_pdf_sha256 text,
    p_consent_comparison_result boolean DEFAULT false,
    p_consent_important_matters boolean DEFAULT false,
    p_consent_personal_info boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id                 uuid;
    v_run_agency                  uuid;
    v_run_status                  text;
    v_customer_decision           text;
    v_compare_presented_at        timestamptz;
    v_meeting_scene               varchar;
    v_important_matters_delivered boolean;
    v_recording_mode              text;
    v_post_record_status          text;
    v_exception_route             boolean;
    v_snapshot_count              int;
    v_unresolved_count            int;
    v_insurer_list_event_count    int;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'finalize_run: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status, customer_decision, compare_presented_at,
           meeting_scene, important_matters_delivered, recording_mode, post_record_status
      INTO v_run_agency, v_run_status, v_customer_decision, v_compare_presented_at,
           v_meeting_scene, v_important_matters_delivered, v_recording_mode, v_post_record_status
      FROM public.run
     WHERE id = p_run_id
     FOR UPDATE;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'finalize_run: run % not found', p_run_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'finalize_run: run does not belong to caller''s agency';
    END IF;

    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'finalize_run: run % not found or not in draft status', p_run_id;
    END IF;

    IF v_customer_decision IS NULL
       OR v_customer_decision NOT IN ('compare', 'renewal_no_change', 'information_refused', 'comparison_waived')
    THEN
        RAISE EXCEPTION 'finalize_run: customer_decision is not set to a valid value';
    END IF;
    v_exception_route := (v_customer_decision <> 'compare');

    -- 田島様2026-08-04ご判断: meeting_scene・recording_modeを確定時必須とする
    IF v_meeting_scene IS NULL THEN
        RAISE EXCEPTION 'finalize_run: meeting_scene must be set before finalization';
    END IF;
    IF v_recording_mode IS NULL THEN
        RAISE EXCEPTION 'finalize_run: recording_mode must be set before finalization';
    END IF;

    SELECT count(*) INTO v_snapshot_count FROM public.snapshot s WHERE s.run_id = p_run_id;
    IF v_snapshot_count = 0 THEN
        RAISE EXCEPTION 'finalize_run: snapshot not found for run';
    END IF;
    IF v_snapshot_count > 1 THEN
        RAISE EXCEPTION 'finalize_run: multiple snapshot rows found for run (data integrity issue)';
    END IF;

    IF EXISTS (SELECT 1 FROM public.snapshot s WHERE s.run_id = p_run_id AND s.unresolved_items IS NULL) THEN
        RAISE EXCEPTION 'finalize_run: snapshot.unresolved_items is NULL (data integrity issue)';
    END IF;

    SELECT coalesce(array_length(s.unresolved_items, 1), 0) INTO v_unresolved_count
      FROM public.snapshot s WHERE s.run_id = p_run_id;
    IF v_unresolved_count > 0 THEN
        RAISE EXCEPTION 'finalize_run: unresolved_items remain (% items)', v_unresolved_count;
    END IF;

    SELECT count(*) INTO v_insurer_list_event_count
      FROM public.audit_event
     WHERE run_id = p_run_id AND event_type = 'insurer_list_presented';
    IF v_insurer_list_event_count = 0 THEN
        RAISE EXCEPTION 'finalize_run: insurer_list_presented not recorded';
    END IF;

    IF NOT v_exception_route AND v_recording_mode = 'post_record' AND v_post_record_status IS DISTINCT FROM 'phase2_done' THEN
        RAISE EXCEPTION 'finalize_run: post_record phase2 not completed';
    END IF;

    IF NOT v_exception_route AND v_compare_presented_at IS NULL THEN
        RAISE EXCEPTION 'finalize_run: compare_presented_at not set';
    END IF;

    IF NOT v_important_matters_delivered THEN
        RAISE EXCEPTION 'finalize_run: important_matters_delivered not confirmed';
    END IF;

    IF p_pdf_object_key IS NULL OR btrim(p_pdf_object_key) = '' THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key is required';
    END IF;
    IF p_pdf_object_key NOT LIKE ('runs/' || p_run_id::text || '/%') THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key does not belong to this run';
    END IF;
    IF p_pdf_sha256 IS NULL OR p_pdf_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_sha256 is not a valid SHA-256 hex digest';
    END IF;

    UPDATE public.run SET
        pdf_object_key = p_pdf_object_key,
        pdf_sha256     = p_pdf_sha256,
        finalized_at   = now(),
        finalized_by   = v_operator_id,
        run_status     = 'finalized',
        export_status  = 'completed',
        updated_at     = now()
    WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'run_finalized', v_operator_id, jsonb_build_object('finalized_at', now()));

    IF p_consent_comparison_result THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_comparison_result', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;

    IF p_consent_important_matters THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_important_matters', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;

    IF p_consent_personal_info THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_personal_info', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;
END;
$$;


-- ── 3a. 子テーブルのrun_id付替え自体を禁止 ───────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_parent_run_not_finalized()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
    v_run_status text;
BEGIN
    IF current_user <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    -- run_id自体の変更を禁止する（田島様2026-08-04ご指摘3a）。
    -- 従来はNEW.run_idの状態のみを検査していたため、確定済みrunの子行を
    -- 別のdraft run側へ付け替えるUPDATEが、旧親runの状態を検査されずに
    -- 通ってしまっていた。run_idは作成後に変更する正当な業務理由がない
    -- ため、変更自体を一律禁止する。
    IF TG_OP = 'UPDATE' AND NEW.run_id IS DISTINCT FROM OLD.run_id THEN
        RAISE EXCEPTION '%: run_id cannot be changed after creation (attempted % -> %)', TG_TABLE_NAME, OLD.run_id, NEW.run_id;
    END IF;

    SELECT run_status INTO v_run_status FROM public.run WHERE id = NEW.run_id;
    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION '%: parent run is %, direct modification no longer permitted (run %)', TG_TABLE_NAME, v_run_status, NEW.run_id;
    END IF;

    RETURN NEW;
END;
$$;


-- ── 3b. archived未検査だった3関数にarchivedチェックを追加 ───────────────
CREATE OR REPLACE FUNCTION public.save_property_profile(
    p_run_id uuid, p_line_code text, p_municipality_code text, p_attributes jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id   uuid;
    v_agency_id     uuid;
    v_run_agency    uuid;
    v_run_status    text;
    v_customer_type text;
    v_flood_grade   int;
    v_complete      boolean;
    v_save_id       uuid := gen_random_uuid();
BEGIN
    SELECT id, agency_id INTO v_operator_id, v_agency_id
    FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 呼出ユーザーが特定できません';
    END IF;

    SELECT agency_id, customer_type, run_status INTO v_run_agency, v_customer_type, v_run_status
    FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 対象runが存在しません';
    END IF;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'save_property_profile: 権限がありません（他代理店のrun）';
    END IF;

    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION 'save_property_profile: run is % ,property profile can no longer be modified', v_run_status;
    END IF;

    SELECT flood_grade INTO v_flood_grade FROM public.flood_zone_master WHERE municipality_code = p_municipality_code;

    IF v_customer_type = 'individual' THEN
        v_complete :=
            (p_attributes->>'ownership_type') IS NOT NULL
            AND (p_attributes->>'has_household_goods') IS NOT NULL
            AND (p_attributes->>'earthquake_insurance') IS NOT NULL
            AND (
                (p_attributes->>'ownership_type') IS DISTINCT FROM 'rental'
                OR (
                    (p_attributes->>'renter_liability') IS NOT NULL
                    AND (p_attributes->>'personal_liability') IS NOT NULL
                )
            );
    ELSIF v_customer_type = 'corporate' THEN
        v_complete :=
            (p_attributes->>'property_count') IS NOT NULL
            AND (p_attributes->>'property_count')::int >= 1
            AND (
                (p_attributes->>'property_count')::int = 1
                OR (
                    (p_attributes->>'schedule_reference')::boolean IS TRUE
                    AND (p_attributes->>'schedule_acknowledged')::boolean IS TRUE
                )
            );
    ELSE
        v_complete := false;
    END IF;

    INSERT INTO public.property_profile (run_id, line_code, municipality_code, attributes, last_save_id, updated_at)
    VALUES (p_run_id, p_line_code, p_municipality_code, p_attributes, v_save_id, now())
    ON CONFLICT (run_id, line_code) DO UPDATE
        SET municipality_code = EXCLUDED.municipality_code,
            attributes        = EXCLUDED.attributes,
            last_save_id      = EXCLUDED.last_save_id,
            updated_at        = now();

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (
        p_run_id,
        'property_profile_recorded',
        v_operator_id,
        jsonb_build_object(
            'line_code', p_line_code,
            'customer_type', v_customer_type,
            'municipality_code', p_municipality_code,
            'flood_grade', v_flood_grade,
            'complete', v_complete,
            'save_id', v_save_id
        )
    );

    RETURN v_save_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_compare_presented(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id  uuid;
    v_run_agency   uuid;
    v_run_status   text;
    v_already      timestamptz;
    v_active_count int;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_compare_presented: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status, compare_presented_at INTO v_run_agency, v_run_status, v_already
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_compare_presented: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_compare_presented: run does not belong to caller''s agency';
    END IF;
    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION 'record_compare_presented: run is %', v_run_status;
    END IF;
    IF v_already IS NOT NULL THEN
        RAISE EXCEPTION 'record_compare_presented: already presented';
    END IF;

    SELECT count(*) INTO v_active_count FROM public.candidate WHERE run_id = p_run_id AND status = 'active';
    IF v_active_count = 0 THEN
        RAISE EXCEPTION 'record_compare_presented: at least one active candidate is required';
    END IF;

    UPDATE public.run SET compare_presented_at = now() WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'compare_presented', v_operator_id, jsonb_build_object('presented_at', now()));
END;
$$;

CREATE OR REPLACE FUNCTION public.record_insurer_list_presented(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_insurer_list_presented: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run does not belong to caller''s agency';
    END IF;
    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run is %', v_run_status;
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'insurer_list_presented', v_operator_id, jsonb_build_object('auto_recorded', true));
END;
$$;


-- ── 4. candidate状態遷移2関数: runを先にロックする順序へ変更 ────────────
CREATE OR REPLACE FUNCTION public.exclude_candidate(
    p_candidate_id uuid, p_reason_code text DEFAULT NULL::text, p_reason_text text DEFAULT NULL::text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id      uuid;
    v_run_id           uuid;
    v_run_agency       uuid;
    v_run_status       text;
    v_compare_presented timestamptz;
    v_current_status   text;
    v_prior_reason_code text;
    v_prior_reason_text text;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: no active operator for the calling session';
    END IF;

    IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
        RAISE EXCEPTION 'exclude_candidate: reason code is required';
    END IF;
    IF p_reason_code = 'R-999' AND (p_reason_text IS NULL OR btrim(p_reason_text) = '') THEN
        RAISE EXCEPTION 'exclude_candidate: reason text is required when reason code is R-999';
    END IF;

    -- 田島様2026-08-04ご指摘4: runを先にロックしてからcandidateを読む
    -- （044で他5関数に適用した順序と統一。finalize_runとの並行実行を直列化する）
    SELECT run_id INTO v_run_id FROM public.candidate WHERE id = p_candidate_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: candidate % not found', p_candidate_id;
    END IF;

    SELECT agency_id, run_status, compare_presented_at INTO v_run_agency, v_run_status, v_compare_presented
      FROM public.run WHERE id = v_run_id FOR UPDATE;

    SELECT status, exclusion_reason_code, excluded_reason
      INTO v_current_status, v_prior_reason_code, v_prior_reason_text
      FROM public.candidate WHERE id = p_candidate_id FOR UPDATE;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'exclude_candidate: candidate does not belong to caller''s agency';
    END IF;

    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION 'exclude_candidate: run is %, candidate can no longer be modified', v_run_status;
    END IF;

    IF v_current_status = 'excluded' THEN
        RAISE EXCEPTION 'exclude_candidate: candidate is already excluded';
    END IF;

    UPDATE public.candidate
       SET status = 'excluded',
           exclusion_reason_code = p_reason_code,
           excluded_reason = nullif(btrim(coalesce(p_reason_text,'')),''),
           excluded_by = v_operator_id,
           excluded_at = now()
     WHERE id = p_candidate_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'exclusion_reason_recorded', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'reason', p_reason_text));

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'exclusion_reason_coded', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'code', p_reason_code, 'memo', p_reason_text));

    IF v_compare_presented IS NOT NULL THEN
        UPDATE public.run SET compare_presented_at = NULL WHERE id = v_run_id;
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (v_run_id, 'compare_presented', v_operator_id,
                jsonb_build_object(
                    'invalidated', true,
                    'invalidated_reason', 'candidate_excluded_after_presentation',
                    'candidate_id', p_candidate_id,
                    'previous_presented_at', v_compare_presented,
                    'before', jsonb_build_object('status', v_current_status, 'reason_code', v_prior_reason_code, 'reason_text', v_prior_reason_text),
                    'after', jsonb_build_object('status', 'excluded', 'reason_code', p_reason_code, 'reason_text', p_reason_text)
                ));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_candidate_coverage_status(p_candidate_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id       uuid;
    v_run_id            uuid;
    v_run_agency        uuid;
    v_run_status        text;
    v_compare_presented timestamptz;
    v_candidate_status  text;
    v_current_status    text;
BEGIN
    IF p_status IS NULL OR p_status NOT IN ('full','partial','none') THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: invalid status %', p_status;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: no active operator for the calling session';
    END IF;

    -- 田島様2026-08-04ご指摘4: runを先にロックしてからcandidateを読む
    SELECT run_id INTO v_run_id FROM public.candidate WHERE id = p_candidate_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate % not found', p_candidate_id;
    END IF;

    SELECT agency_id, run_status, compare_presented_at INTO v_run_agency, v_run_status, v_compare_presented
      FROM public.run WHERE id = v_run_id FOR UPDATE;

    SELECT status, coverage_status INTO v_candidate_status, v_current_status
      FROM public.candidate WHERE id = p_candidate_id FOR UPDATE;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate does not belong to caller''s agency';
    END IF;

    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: run is %, candidate can no longer be modified', v_run_status;
    END IF;

    IF v_candidate_status = 'excluded' THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate is excluded, coverage status can no longer be modified';
    END IF;

    IF v_current_status IS NOT DISTINCT FROM p_status THEN
        RETURN;
    END IF;

    UPDATE public.candidate SET coverage_status = p_status WHERE id = p_candidate_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'candidate_coverage_status_updated', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'status', p_status,
                                'old_status', v_current_status));

    IF v_compare_presented IS NOT NULL THEN
        UPDATE public.run SET compare_presented_at = NULL WHERE id = v_run_id;
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (v_run_id, 'compare_presented', v_operator_id,
                jsonb_build_object(
                    'invalidated', true,
                    'invalidated_reason', 'candidate_coverage_status_changed_after_presentation',
                    'candidate_id', p_candidate_id,
                    'previous_presented_at', v_compare_presented,
                    'before', jsonb_build_object('coverage_status', v_current_status),
                    'after', jsonb_build_object('coverage_status', p_status)
                ));
    END IF;
END;
$$;
