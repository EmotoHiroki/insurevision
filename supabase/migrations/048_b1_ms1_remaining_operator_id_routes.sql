-- ============================================================================
-- 048_b1_ms1_remaining_operator_id_routes.sql
--
-- 背景（田島様2026-08-01ご指摘Dの後半「全APIルートを棚卸しし、クライアント
-- から供給されるoperatorIdへの依存の有無、是正内容および実測結果をご提示
-- ください」への完全対応）:
--
--   040で `/api/run/[id]/smartphone-confirm` を、045で
--   `/api/run/[id]/plan-selection` を是正したが、**同型の実装が残る
--   APIルートが4件あった**ことを、第4便の送付前レビューで発見した。
--   田島様のご依頼は個別ルートではなく「全APIルートの棚卸し」であり、
--   名指しされた2件のみを是正して同型の箇所を残していた状態は、
--   「指摘された箇所だけを直し、同型の箇所を残す」という当方が過去に
--   繰り返してきた不備の再発である。
--
--   残っていた4ルートと、それぞれの問題:
--     1. `/api/finalize`
--        - リクエスト本文の `operatorId` を `audit_event.operator_id` へ記録
--        - `consent_important_matters`・`consent_personal_info` の2イベントが
--          finalize_run のトランザクション**外**で挿入されており、確定は
--          成功したが同意証跡だけ失敗する状態を作りうる
--        - 上記INSERTのエラーを確認せず `{success:true}` を返す
--     2. `/api/run/[id]/consent`
--        - `operatorId` を `run.electronic_consent_operator_id` と
--          `audit_event.operator_id` の両方へ記録
--     3. `/api/run/[id]/paper-confirm`
--     4. `/api/run/[id]/important-matters`
--        - いずれも `operatorId` を監査ログへ記録し、run更新と
--          audit_event記録が別処理（原子性なし）、INSERT失敗を検査しない
--
--   なお、これら4ルートについても `audit_event_insert_own_agency` ポリシー
--   （012・013）の WITH CHECK により、他operatorへのなりすまし自体はRLSで
--   拒否される。しかしこれはRLSに間接的に依存した状態であり、
--   「クライアント供給の値を信用する構造」という田島様のご指摘は正しい。
--   また run更新とaudit_event記録の非原子性・INSERT失敗の握り潰しは
--   RLSでは防げない。
--
-- 【対応】
--   本エンゲージメントで確立したパターン（呼出者を auth.uid() から導出し、
--   agency照合・is_active検査・確定後Freezeを関数内で行い、run更新と
--   audit_event記録を単一トランザクションで実施する SECURITY DEFINER 関数）
--   へ4ルートすべてを統一する。
--
--   finalize_run については、同意2イベントを引数として受け取り、確定処理と
--   同一トランザクション内で記録するよう拡張する。旧シグネチャ（4引数）は
--   明示的にDROPし、併存させない（030と同じ方針）。
--
--   あわせて、新たに専任関数を持つことになった4種のevent_typeを
--   `enforce_audit_event_protected_types` の保護対象に追加する。
-- ============================================================================

-- ── 1. 電子同意の記録 ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_electronic_consent(
    p_run_id uuid,
    p_status text,
    p_method text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
    v_now         timestamptz := now();
BEGIN
    IF p_status IS NULL OR p_status NOT IN ('agreed', 'declined', 'face_confirmed', 'not_recorded') THEN
        RAISE EXCEPTION 'record_electronic_consent: invalid status %', p_status;
    END IF;
    IF p_method IS NOT NULL AND p_method NOT IN ('email', 'url_share', 'qr_code', 'face_to_face') THEN
        RAISE EXCEPTION 'record_electronic_consent: invalid method %', p_method;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_electronic_consent: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_electronic_consent: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_electronic_consent: run does not belong to caller''s agency';
    END IF;
    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'record_electronic_consent: run not editable';
    END IF;

    UPDATE public.run
       SET electronic_consent_status = p_status,
           electronic_consent_confirmed_at = v_now,
           electronic_consent_operator_id = v_operator_id,
           electronic_consent_method = COALESCE(p_method, electronic_consent_method),
           -- 同意なしの場合は紙面確認モードへ自動切替（現行アプリの挙動を踏襲）
           paper_confirmation_status = CASE WHEN p_status = 'declined' THEN 'pending' ELSE paper_confirmation_status END,
           smartphone_conf_status = CASE WHEN p_status = 'declined' THEN 'paper_fallback' ELSE smartphone_conf_status END
     WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'electronic_consent_recorded', v_operator_id,
            jsonb_build_object('status', p_status, 'method', p_method, 'confirmed_at', v_now));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_electronic_consent(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_electronic_consent(uuid, text, text) TO authenticated;


-- ── 2. 紙面確認の記録 ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_paper_confirmation(
    p_run_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
    v_now         timestamptz := now();
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_paper_confirmation: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_paper_confirmation: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_paper_confirmation: run does not belong to caller''s agency';
    END IF;
    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'record_paper_confirmation: run not editable';
    END IF;

    UPDATE public.run
       SET paper_confirmation_status = 'completed',
           paper_confirmation_completed_at = v_now
     WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'paper_confirmation_completed', v_operator_id,
            jsonb_build_object('completed_at', v_now));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_paper_confirmation(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_paper_confirmation(uuid) TO authenticated;


-- ── 3. 重要事項説明書の交付記録 ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_important_matters_delivery(
    p_run_id uuid,
    p_delivery_method text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
    v_now         timestamptz := now();
BEGIN
    IF p_delivery_method IS NULL OR p_delivery_method NOT IN ('electronic', 'paper') THEN
        RAISE EXCEPTION 'record_important_matters_delivery: invalid delivery method %', p_delivery_method;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_important_matters_delivery: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_important_matters_delivery: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_important_matters_delivery: run does not belong to caller''s agency';
    END IF;
    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'record_important_matters_delivery: run not editable';
    END IF;

    UPDATE public.run
       SET important_matters_delivered = true,
           important_matters_delivered_at = v_now,
           important_matters_delivery_method = p_delivery_method
     WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'important_matters_delivery_confirmed', v_operator_id,
            jsonb_build_object('delivery_method', p_delivery_method, 'delivered_at', v_now));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_important_matters_delivery(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_important_matters_delivery(uuid, text) TO authenticated;


-- ── 4. finalize_run: 同意2イベントを確定と同一トランザクションへ取り込む ──
-- 旧シグネチャ（4引数）は併存させず明示的にDROPする（030と同じ方針）。
DROP FUNCTION IF EXISTS public.finalize_run(uuid, text, text, boolean);

CREATE FUNCTION public.finalize_run(
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

    IF v_meeting_scene IS NOT NULL AND NOT v_important_matters_delivered THEN
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

    -- 同意2イベントを確定と同一トランザクション内で記録する
    -- （従来はAPIルート側でRPC呼出しの後に別途INSERTしており、確定は成功
    --   したが同意証跡だけ失敗する状態を作りうる構造だった）
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

REVOKE EXECUTE ON FUNCTION public.finalize_run(uuid, text, text, boolean, boolean, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.finalize_run(uuid, text, text, boolean, boolean, boolean) TO authenticated;


-- ── 5. 新たに専任関数を持つevent_typeを保護対象へ追加 ───────────────────
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
        -- 048で専任関数へ移行した4種
        'electronic_consent_recorded', 'paper_confirmation_completed',
        'important_matters_delivery_confirmed',
        'consent_important_matters', 'consent_personal_info'
    ) THEN
        RAISE EXCEPTION 'audit_event: event_type "%" can only be recorded via its dedicated function, not by direct insert', NEW.event_type;
    END IF;
    RETURN NEW;
END;
$$;
