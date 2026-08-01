-- ============================================================================
-- 044_b1_ms1_remaining_mutating_rpc_concurrency.sql
--
-- 背景（task F: 全書込みRPCへの同時実行制御。田島様は
-- update_candidate_coverage_status・exclude_candidate・finalize_run・
-- issue_smartphone_confirm_token・confirm_smartphoneの5関数を名指しで
-- ご指摘。これらは042/038/041で対応済み）。
--
-- 田島様のご指摘対象ではないが、同型のレースコンディションが残って
-- いないか全SECURITY DEFINER関数を棚卸ししたところ、以下3件に
-- 「run_status確認 → その後UPDATE」という、ロックなしの同型の穴を発見:
--   - save_property_profile（finalized判定後にUPSERT）
--   - update_snapshot_redundancy_decisions（editable判定後にUPDATE）
--   - update_snapshot_resolution_memo（editable判定後にUPDATE）
-- いずれも、判定とUPDATEの間にfinalize_run側のFOR UPDATEロックと
-- 交差しないため、finalize処理と競合するタイミングで確定後の書込みが
-- すり抜ける可能性がある。
--
-- さらに、record_insurer_list_presented（039で新設）には
-- run_status='finalized'に対するフリーズ判定が一切存在しないことも
-- 判明した（新設時に他の類似関数のパターンを踏襲し忘れていた）。
--
-- 【対応】
--   対象runの行を`SELECT ... FOR UPDATE`でロックしてから状態判定する
--   よう統一。record_insurer_list_presentedにはfinalizedチェックを追加。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.save_property_profile(p_run_id uuid, p_line_code text, p_municipality_code text, p_attributes jsonb)
RETURNS uuid
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

    IF v_run_status = 'finalized' THEN
        RAISE EXCEPTION 'save_property_profile: run is already finalized, property profile can no longer be modified';
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

CREATE OR REPLACE FUNCTION public.update_snapshot_redundancy_decisions(p_snapshot_id uuid, p_redundancy_decisions jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_agency_id  uuid;
    v_run_id     uuid;
    v_run_agency uuid;
    v_run_status text;
BEGIN
    SELECT agency_id INTO v_agency_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_agency_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: no active operator for the calling session';
    END IF;

    SELECT s.run_id INTO v_run_id FROM public.snapshot s WHERE s.id = p_snapshot_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: snapshot not found';
    END IF;

    SELECT r.agency_id, r.run_status INTO v_run_agency, v_run_status
      FROM public.run r WHERE r.id = v_run_id FOR UPDATE;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: run not editable';
    END IF;

    UPDATE public.snapshot s
       SET redundancy_decisions = p_redundancy_decisions
     WHERE s.id = p_snapshot_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_snapshot_resolution_memo(p_snapshot_id uuid, p_resolution_memo text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_agency_id  uuid;
    v_run_id     uuid;
    v_run_agency uuid;
    v_run_status text;
BEGIN
    SELECT agency_id INTO v_agency_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_agency_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: no active operator for the calling session';
    END IF;

    SELECT s.run_id INTO v_run_id FROM public.snapshot s WHERE s.id = p_snapshot_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: snapshot not found';
    END IF;

    SELECT r.agency_id, r.run_status INTO v_run_agency, v_run_status
      FROM public.run r WHERE r.id = v_run_id FOR UPDATE;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: run not editable';
    END IF;

    UPDATE public.snapshot s
       SET resolution_memo = p_resolution_memo
     WHERE s.id = p_snapshot_id;
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
    IF v_run_status = 'finalized' THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run is already finalized';
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'insurer_list_presented', v_operator_id, jsonb_build_object('auto_recorded', true));
END;
$$;
