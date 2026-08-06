-- ============================================================================
-- 063_b1_ms1_redundancy_audit_payload_derived_from_saved_state.sql
--
-- migration 061 の是正。
--
-- 【061で残っていた問題】
--   061は「誰が証跡を書けるか」を正した（画面からの直接INSERTを廃し、
--   専任関数の内部でのみ記録するようにした）。しかし
--   「記録される内容が、実際に保存された内容と一致しているか」は
--   検査していなかった。
--
--   061では、保存内容は `p_redundancy_decisions` から、
--   証跡の内容は `p_item_key` / `p_decision` / `p_reason` から、
--   それぞれ独立に組み立てていた。両者が一致することを誰も確認していないため、
--   呼出し側が次のように食い違う値を渡すと、
--   「保存されていない判断が、証跡としては残る」状態を作ることができた。
--
--     p_redundancy_decisions = []                     ← 実際には何も保存しない
--     p_item_key = '人身傷害×傷害保険'
--     p_decision = 'keep'
--     p_reason   = 'お客様と継続で合意'                ← 証跡にはこれが残る
--
--   `audit_event` は追記専用でUPDATE・DELETEを禁止しているため、
--   一度書かれた事実と異なる証跡は後から訂正できない。
--   比較推奨販売の証跡として用いる以上、
--   「書ける者を絞る」だけでは不十分で、「書かれる内容が事実であること」まで
--   担保する必要がある。
--
-- 【是正方針】
--   証跡の内容を引数から組み立てるのをやめ、
--   **実際に保存する `p_redundancy_decisions` の中の該当要素から導出する**。
--   ・`p_item_key` が保存内容の中に存在しない場合は拒否する
--   ・`p_decision` が渡された場合、保存内容側の判断と一致しなければ拒否する
--   ・証跡に載せる item_key・decision・reason は、すべて保存内容側の値を使う
--
--   これにより、証跡は常に「そのとき保存された内容そのもの」を指すことになり、
--   呼出し側が独自の文言を証跡へ書き込む経路が無くなる。
--
--   あわせて、追記専用テーブルへ際限なく書き込めないよう理由の長さを制限する。
--
-- 引数の形（5引数）は 061 から変更しない。したがって関数の削除・再作成は不要で、
-- PostgREST のスキーマキャッシュに影響しない。
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
    v_operator_id     uuid;
    v_agency_id       uuid;
    v_run_id          uuid;
    v_run_agency      uuid;
    v_run_status      text;
    v_saved           jsonb;
    v_saved_decision  text;
    v_saved_reason    text;
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

    IF p_redundancy_decisions IS NULL OR jsonb_typeof(p_redundancy_decisions) <> 'array' THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: p_redundancy_decisions must be a json array (got %)',
            coalesce(jsonb_typeof(p_redundancy_decisions), 'null');
    END IF;

    UPDATE public.snapshot s
       SET redundancy_decisions = p_redundancy_decisions
     WHERE s.id = p_snapshot_id;

    -- 判断内容が渡された場合のみ証跡を残す。
    -- 判断の取り消し（項目の削除）は「判断の記録」ではないため記録しない。
    IF p_item_key IS NOT NULL THEN
        -- 証跡の内容は、引数ではなく「実際に保存した内容」から取り出す。
        SELECT elem INTO v_saved
          FROM jsonb_array_elements(p_redundancy_decisions) AS elem
         WHERE elem ->> 'item_key' = p_item_key
         LIMIT 1;

        IF v_saved IS NULL THEN
            RAISE EXCEPTION 'update_snapshot_redundancy_decisions: p_item_key % is not present in the saved decisions, refusing to record an audit event that does not reflect stored state', p_item_key;
        END IF;

        v_saved_decision := v_saved ->> 'decision';
        v_saved_reason   := coalesce(v_saved ->> 'reason', '');

        IF v_saved_decision IS NULL OR v_saved_decision NOT IN ('keep', 'remove') THEN
            RAISE EXCEPTION 'update_snapshot_redundancy_decisions: stored decision for % must be ''keep'' or ''remove'' (got %)',
                p_item_key, coalesce(v_saved_decision, '<NULL>');
        END IF;

        -- 引数で判断が渡された場合は、保存内容と一致していることを確認する。
        -- 呼出し側の取り違えを黙って通さないための検査であり、
        -- 証跡に載せる値そのものは常に保存内容側を使う。
        IF p_decision IS NOT NULL AND p_decision IS DISTINCT FROM v_saved_decision THEN
            RAISE EXCEPTION 'update_snapshot_redundancy_decisions: p_decision (%) disagrees with the stored decision (%) for %',
                p_decision, v_saved_decision, p_item_key;
        END IF;

        -- 追記専用テーブルへ際限なく書き込めないようにする。
        IF length(v_saved_reason) > 1000 THEN
            RAISE EXCEPTION 'update_snapshot_redundancy_decisions: reason for % is too long (% characters, limit 1000)',
                p_item_key, length(v_saved_reason);
        END IF;

        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (v_run_id, 'redundancy_resolution_recorded', v_operator_id,
                jsonb_build_object(
                    'item_key', v_saved ->> 'item_key',
                    'decision', v_saved_decision,
                    'reason',   v_saved_reason
                ));
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb, text, text, text) TO authenticated;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $$
DECLARE v_cnt int; v_src text; v_oid oid;
BEGIN
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'update_snapshot_redundancy_decisions';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '063 failed: expected exactly 1 update_snapshot_redundancy_decisions, found %', v_cnt;
    END IF;

    SELECT p.oid, p.prosrc INTO v_oid, v_src FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'update_snapshot_redundancy_decisions';

    -- 証跡の内容が保存内容から導出されていること
    IF v_src NOT LIKE '%jsonb_array_elements(p_redundancy_decisions)%' THEN
        RAISE EXCEPTION '063 failed: the audit payload is not derived from the saved decisions';
    END IF;
    IF v_src NOT LIKE '%is not present in the saved decisions%' THEN
        RAISE EXCEPTION '063 failed: missing the guard that rejects an item_key absent from the saved decisions';
    END IF;
    IF v_src NOT LIKE '%disagrees with the stored decision%' THEN
        RAISE EXCEPTION '063 failed: missing the guard that rejects a p_decision disagreeing with stored state';
    END IF;

    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '063 failed: authenticated cannot execute the function';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '063 failed: anon can execute the function';
    END IF;

    RAISE NOTICE '063: redundancy audit payload is now derived from the state actually saved';
END;
$$;
