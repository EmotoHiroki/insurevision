-- ============================================================================
-- 028_b1_ms1_candidate_functions_null_safety_and_freeze.sql
--
-- 状態: 本番適用済み
--
-- 背景（田島様2026-07-30ご指摘A-3への対応）:
--
--   1. update_candidate_coverage_status の `IF p_status NOT IN (...)` は、
--      p_status が NULL の場合 NOT IN の結果自体が NULL となり IF に入らず、
--      UPDATE文まで到達する。実測の結果 candidate.coverage_status は
--      NULL許容・既定値なしであるため、実際にNULLが書き込まれ、
--      candidate_coverage_status_updated イベントも記録されてしまう。
--      `p_status IS NULL OR p_status NOT IN (...)` へ修正する。
--
--   2. 両関数の `v_run_agency <> (...)` も、比較対象がNULLであれば
--      NULLを返しIFに入らない。運用上 operator.agency_id・run.agency_id は
--      NOT NULLだが、念のため IS DISTINCT FROM へ変更し、NULL同士の比較でも
--      確実に検査が効くようにする。
--
--   3. 両関数とも、対象runが確定済みかどうかを検査していなかった。
--      active な同一代理店operatorがRPCを直接呼べば、確定後でも除外状態・
--      補償状況を変更できる状態だった（実機のrunは下書きのため未検証だが、
--      コードレビューで判明）。run.finalized_at IS NOT NULL であれば
--      拒否するチェックを両関数に追加する。
--
--   4. update_candidate_coverage_status について、現在値と同一のstatusを
--      指定した場合はUPDATE・audit_event記録の両方をスキップするよう変更。
--      A-5（画面反映遅延・重複監査イベント）のご指摘で提案された
--      「RPC側で更新前後が同値の場合に状態変更イベントを記録しない」対応を、
--      関数側の恒久対応として実施する。
--
-- 対応外（第4の未決定事項。#40で田島様のご判断を仰ぐ）:
--   exclude_candidate は、理由コードがR-999以外の場合、理由コード・理由文の
--   双方がNULLでも除外を許容する（現行アプリの挙動を踏襲）。これを
--   Fail-Closed（理由必須）に変更するかどうかは業務判断であるため、
--   本migrationでは変更しない。
--
-- 補足: snapshot.redundancy_decisions・resolution_memo の確定後の扱い
--   （更新可能とするか確定前限定とするか）は、第3段階のFreeze設計と
--   あわせて整理する（#40）。本migrationはcandidateの2関数のみを対象とする。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exclude_candidate(
    p_candidate_id uuid,
    p_reason_code text DEFAULT NULL,
    p_reason_text text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id  uuid;
    v_run_agency   uuid;
    v_finalized_at timestamptz;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: no active operator for the calling session';
    END IF;

    SELECT r.agency_id, r.finalized_at INTO v_run_agency, v_finalized_at
      FROM public.candidate c
      JOIN public.run r ON r.id = c.run_id
     WHERE c.id = p_candidate_id;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: candidate % not found', p_candidate_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'exclude_candidate: candidate does not belong to caller''s agency';
    END IF;

    IF v_finalized_at IS NOT NULL THEN
        RAISE EXCEPTION 'exclude_candidate: run is already finalized, candidate can no longer be modified';
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

CREATE OR REPLACE FUNCTION public.update_candidate_coverage_status(
    p_candidate_id uuid,
    p_status text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id     uuid;
    v_run_id          uuid;
    v_run_agency      uuid;
    v_finalized_at    timestamptz;
    v_current_status  text;
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

    SELECT c.run_id, r.agency_id, r.finalized_at, c.coverage_status
      INTO v_run_id, v_run_agency, v_finalized_at, v_current_status
      FROM public.candidate c
      JOIN public.run r ON r.id = c.run_id
     WHERE c.id = p_candidate_id;

    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate % not found', p_candidate_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate does not belong to caller''s agency';
    END IF;

    IF v_finalized_at IS NOT NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: run is already finalized, candidate can no longer be modified';
    END IF;

    -- 値が変化しない場合はUPDATE・audit_event記録の両方をスキップする
    -- （田島様2026-07-30ご指摘A-5：連打・二重発火時の重複イベント抑止）。
    IF v_current_status IS NOT DISTINCT FROM p_status THEN
        RETURN;
    END IF;

    UPDATE public.candidate SET coverage_status = p_status WHERE id = p_candidate_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'candidate_coverage_status_updated', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'status', p_status,
                                'old_status', v_current_status));
END;
$$;
