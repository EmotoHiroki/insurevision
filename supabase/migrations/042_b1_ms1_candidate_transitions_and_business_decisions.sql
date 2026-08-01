-- ============================================================================
-- 042_b1_ms1_candidate_transitions_and_business_decisions.sql
--
-- 背景（田島様2026-08-01ご指摘Eへの対応。028で#40として保留していた
-- 業務判断について、田島様が今回2件とも確定された）:
--
-- 【業務方針（田島様確定・2026-08-01）】
--   1. exclude_candidateは、すべての除外で理由コードを必須とする。
--      R-999の場合は理由文も必須（既存どおり）。
--   2. 比較提示後（compare_presented_at記録後）の候補変更は許容するが、
--      変更時に提示済み状態を無効化し、再提示を必須とする。以前の提示
--      履歴（audit_event）は削除せず、無効化の理由・変更前後の内容・
--      再提示をaudit_eventで追跡する。
--
-- 【既存データの移行方針】
--   実測の結果、理由コードなしの除外済みcandidateが1件（run
--   6d2b9fe7-...、2026-03-20付、理由文はあるがコードなし）存在することを
--   確認した。既存データは過去の事実の記録として変更しない
--   （理由コード必須化は今後の新規除外呼出しにのみ適用する）。
--
-- 【reason_code の体系について・重要な発見】
--   田島様は「理由コードがrestriction_reason_masterに存在し、現在
--   有効であること」の検証を求められたが、実コードを確認したところ、
--   `restriction_reason_master`（accident_history・flood_risk等、
--   物件・引受リスクに関する制限理由の別体系）と、
--   `candidate.exclusion_reason_code`（R-001〜R-999、比較候補を除外する
--   際の理由。UI（`src/app/run/[id]/page.tsx`）にハードコードされた
--   選択肢）は、**互いに無関係などの値も一致しない別々の体系**である
--   ことが判明した。restriction_reason_masterに対する検証を追加すると、
--   R-001〜R-999のいずれも存在しないテーブルと照合することになり、
--   常に失敗する誤った実装になってしまう。この点は証跡資料で別途
--   ご説明し、本migrationではR-001〜R-999の既存CHECK制約（マイグレーション
--   005で定義済み）による検証を維持する。
--
-- 【技術的な是正】
--   ・exclude_candidate: 除外済みcandidateへの再除外を拒否。
--   ・update_candidate_coverage_status: 除外済みcandidateへの
--     coverage_status変更を拒否。
--   ・両関数: 対象candidate行を`SELECT ... FOR UPDATE`でロックし、
--     並行更新時の整合性を確保。
--   ・両関数: 変更後、対象runのcompare_presented_atが設定済みであれば
--     これをNULLへ戻し（再提示を要求する）、無効化の事実・理由・
--     変更前後の値をaudit_eventへ記録する。
--   ・比較提示の記録自体を`record_compare_presented(p_run_id)`という
--     専任関数へ移し（現状はクライアントの直接UPDATE）、「既に提示済み
--     なら再設定しない」という現行のクライアント側チェックをサーバー側
--     でも保証する。
-- ============================================================================

-- ── compare_presented_atの記録を専任関数化 ─────────────────────────────
CREATE OR REPLACE FUNCTION public.record_compare_presented(
    p_run_id uuid
) RETURNS void
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
    IF v_run_status = 'finalized' THEN
        RAISE EXCEPTION 'record_compare_presented: run is already finalized';
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

REVOKE EXECUTE ON FUNCTION public.record_compare_presented(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_compare_presented(uuid) TO authenticated;


-- ── exclude_candidate: 理由コード必須化・再除外拒否・再提示要求・並行制御 ──
CREATE OR REPLACE FUNCTION public.exclude_candidate(
    p_candidate_id uuid,
    p_reason_code text DEFAULT NULL,
    p_reason_text text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id      uuid;
    v_run_id           uuid;
    v_run_agency       uuid;
    v_finalized_at     timestamptz;
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

    -- 田島様2026-08-01確定方針: すべての除外で理由コードを必須とする
    IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
        RAISE EXCEPTION 'exclude_candidate: reason code is required';
    END IF;
    IF p_reason_code = 'R-999' AND (p_reason_text IS NULL OR btrim(p_reason_text) = '') THEN
        RAISE EXCEPTION 'exclude_candidate: reason text is required when reason code is R-999';
    END IF;

    -- 対象candidateをロックしてから状態を読む（並行更新対策）
    SELECT c.run_id, r.agency_id, r.finalized_at, r.compare_presented_at,
           c.status, c.exclusion_reason_code, c.excluded_reason
      INTO v_run_id, v_run_agency, v_finalized_at, v_compare_presented,
           v_current_status, v_prior_reason_code, v_prior_reason_text
      FROM public.candidate c
      JOIN public.run r ON r.id = c.run_id
     WHERE c.id = p_candidate_id
     FOR UPDATE OF c;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: candidate % not found', p_candidate_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'exclude_candidate: candidate does not belong to caller''s agency';
    END IF;

    IF v_finalized_at IS NOT NULL THEN
        RAISE EXCEPTION 'exclude_candidate: run is already finalized, candidate can no longer be modified';
    END IF;

    -- 除外済みcandidateへの再除外を拒否（田島様2026-08-01ご指摘）
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

    -- 田島様2026-08-01確定方針: 比較提示後の変更は許容するが、提示済み
    -- 状態を無効化し再提示を必須とする。提示履歴（audit_event）は削除しない。
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

REVOKE EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exclude_candidate(uuid, text, text) TO authenticated;


-- ── update_candidate_coverage_status: 除外済み拒否・再提示要求・並行制御 ──
CREATE OR REPLACE FUNCTION public.update_candidate_coverage_status(
    p_candidate_id uuid,
    p_status text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id       uuid;
    v_run_id            uuid;
    v_run_agency        uuid;
    v_finalized_at      timestamptz;
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

    SELECT c.run_id, r.agency_id, r.finalized_at, r.compare_presented_at, c.status, c.coverage_status
      INTO v_run_id, v_run_agency, v_finalized_at, v_compare_presented, v_candidate_status, v_current_status
      FROM public.candidate c
      JOIN public.run r ON r.id = c.run_id
     WHERE c.id = p_candidate_id
     FOR UPDATE OF c;

    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate % not found', p_candidate_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate does not belong to caller''s agency';
    END IF;

    IF v_finalized_at IS NOT NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: run is already finalized, candidate can no longer be modified';
    END IF;

    -- 除外済みcandidateへのcoverage_status変更を拒否（田島様2026-08-01ご指摘）
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

REVOKE EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.update_candidate_coverage_status(uuid, text) TO authenticated;
