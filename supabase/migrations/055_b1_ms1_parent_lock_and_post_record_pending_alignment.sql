-- ============================================================================
-- 055_b1_ms1_parent_lock_and_post_record_pending_alignment.sql
--
-- 背景（田島様2026-08-04ご指摘3・再確認レビューへの対応）:
--
--   1. enforce_parent_run_not_finalized は親runの状態を無ロックで読んで
--      いた。finalize_run() は対象run行を FOR UPDATE でロックするが、
--      このトリガーは同じ行をロックせずに読むため、子行の更新と
--      finalize_run() の並行実行に対して直列化が保証されない。
--      田島様のご指摘どおり、親runの検査にも行ロックを使用する。
--
--   2. record_electronic_consent / record_paper_confirmation /
--      record_important_matters_delivery は run_status = 'draft' の
--      場合のみ許可していた。一方、画面（isEditable）はpost_record_pending
--      も編集可能として電子同意・紙面確認・重要事項交付の操作を表示して
--      おり、事後記録（Phase2）の一部としてこれらの操作を行う想定に
--      なっている。画面上は操作できるのにDBで拒否される不整合だった。
--      post_record_pendingでの事後記録操作を許可し、画面とDBの判定を
--      一致させる。
-- ============================================================================

-- ── 1. 親runの状態検査に行ロックを追加 ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_parent_run_not_finalized()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
    v_run_status text;
BEGIN
    IF current_user <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.run_id IS DISTINCT FROM OLD.run_id THEN
        RAISE EXCEPTION '%: run_id cannot be changed after creation (attempted % -> %)', TG_TABLE_NAME, OLD.run_id, NEW.run_id;
    END IF;

    -- 田島様2026-08-04ご指摘3: finalize_run()が対象run行をFOR UPDATEで
    -- ロックするのと同じ行を、ここでもロックしてから状態を読む。これにより
    -- 子行の更新とfinalize_run()の並行実行が直列化され、確定処理の完了前後
    -- のどちらか一方の順序でしか進行できなくなる（中間状態での競合を排除）。
    SELECT run_status INTO v_run_status FROM public.run WHERE id = NEW.run_id FOR UPDATE;
    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION '%: parent run is %, direct modification no longer permitted (run %)', TG_TABLE_NAME, v_run_status, NEW.run_id;
    END IF;

    RETURN NEW;
END;
$$;


-- ── 2. post_record_pendingでの事後記録操作を許可 ─────────────────────────
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
    -- 田島様2026-08-04ご指摘3: post_record_pendingも許可（画面のisEditableと統一）
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'record_electronic_consent: run not editable';
    END IF;

    UPDATE public.run
       SET electronic_consent_status = p_status,
           electronic_consent_confirmed_at = v_now,
           electronic_consent_operator_id = v_operator_id,
           electronic_consent_method = COALESCE(p_method, electronic_consent_method),
           paper_confirmation_status = CASE WHEN p_status = 'declined' THEN 'pending' ELSE paper_confirmation_status END,
           smartphone_conf_status = CASE WHEN p_status = 'declined' THEN 'paper_fallback' ELSE smartphone_conf_status END
     WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'electronic_consent_recorded', v_operator_id,
            jsonb_build_object('status', p_status, 'method', p_method, 'confirmed_at', v_now));
END;
$$;

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
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
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
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
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
