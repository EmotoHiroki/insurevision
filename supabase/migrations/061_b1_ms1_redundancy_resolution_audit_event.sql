-- ============================================================================
-- 061_b1_ms1_redundancy_resolution_audit_event.sql
--
-- 補償重複の判断記録（`redundancy_resolution_recorded`）が、実際には
-- 一度も記録できない状態になっていた点を是正する。
--
-- 【何が起きていたか】
--   ・画面（案件詳細の補償重複タブ）は、判断を保存したあとに
--     `audit_event` へ `redundancy_resolution_recorded` を直接INSERTしていた。
--   ・しかし migration 039・043・051 のトリガー
--     `enforce_audit_event_protected_types` は、この event_type を
--     「専任関数からのみ記録できる保護対象」として、`authenticated` からの
--     直接INSERTを拒否する。
--   ・migration 039 のヘッダーは、その専任関数を
--     `update_snapshot_redundancy_decisions` と想定していたが、
--     同関数は snapshot の更新のみを行い、audit_event を記録していなかった。
--   ・その結果、直接INSERTは必ず失敗し、かつ画面側がエラーを確認せずに
--     「判断を保存しました」と表示していたため、
--     **記録されていないのに記録されたように見える** 状態が続いていた。
--
--   実測（検証環境・実HTTP）:
--     POST /rest/v1/audit_event {event_type: 'redundancy_resolution_recorded'}
--       -> HTTP 400 P0001
--          「audit_event: event_type "redundancy_resolution_recorded" can only be
--            recorded via its dedicated function, not by direct insert」
--
-- 【是正方針】
--   トリガーは `current_user = 'authenticated'` のときのみ拒否するため、
--   `SECURITY DEFINER`（実行者は関数の所有者＝postgres）である本関数の内部からは
--   正しく記録できる。したがって、想定どおり専任関数の側で記録する。
--
--   画面が持っている「どの項目を・どう判断し・理由は何か」を証跡に残すため、
--   任意引数を追加する。既存の2引数呼出しとの互換のため、いずれも既定値を持つ。
--   項目キーが渡された場合のみ記録する（判断の削除操作では記録しない）。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_snapshot_redundancy_decisions(
    p_snapshot_id           uuid,
    p_redundancy_decisions  jsonb,
    p_item_key              text DEFAULT NULL,
    p_decision              text DEFAULT NULL,
    p_reason                text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id uuid;
    v_agency_id   uuid;
    v_run_id      uuid;
    v_run_agency  uuid;
    v_run_status  text;
BEGIN
    SELECT id, agency_id INTO v_operator_id, v_agency_id
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

    -- 判断内容が渡された場合のみ証跡を残す。
    -- 判断の取り消し（項目の削除）は「判断の記録」ではないため記録しない。
    IF p_item_key IS NOT NULL THEN
        IF p_decision IS NULL OR p_decision NOT IN ('keep', 'remove') THEN
            RAISE EXCEPTION 'update_snapshot_redundancy_decisions: p_decision must be ''keep'' or ''remove'' when p_item_key is given (got %)', p_decision;
        END IF;

        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (v_run_id, 'redundancy_resolution_recorded', v_operator_id,
                jsonb_build_object(
                    'item_key', p_item_key,
                    'decision', p_decision,
                    'reason',   coalesce(p_reason, '')
                ));
    END IF;
END;
$$;

-- 旧2引数版は既定値により本関数へ吸収されるため、重複定義が残らないよう明示的に削除する。
DROP FUNCTION IF EXISTS public.update_snapshot_redundancy_decisions(uuid, jsonb);

REVOKE ALL ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb, text, text, text) TO authenticated;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $$
DECLARE v_cnt int; v_src text;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'update_snapshot_redundancy_decisions';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '061 failed: expected exactly 1 update_snapshot_redundancy_decisions, found %', v_cnt;
    END IF;

    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'update_snapshot_redundancy_decisions';
    IF v_src NOT LIKE '%redundancy_resolution_recorded%' THEN
        RAISE EXCEPTION '061 failed: the function does not record the audit event';
    END IF;

    IF NOT has_function_privilege('authenticated',
        (SELECT oid FROM pg_proc WHERE pronamespace='public'::regnamespace
          AND proname='update_snapshot_redundancy_decisions'), 'EXECUTE') THEN
        RAISE EXCEPTION '061 failed: authenticated cannot execute the function';
    END IF;

    RAISE NOTICE '061: redundancy resolution audit event recorded inside the dedicated function';
END;
$$;
