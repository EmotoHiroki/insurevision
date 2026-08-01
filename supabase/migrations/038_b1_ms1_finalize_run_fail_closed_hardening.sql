-- ============================================================================
-- 038_b1_ms1_finalize_run_fail_closed_hardening.sql
--
-- 背景（田島様2026-08-01ご指摘Bへの対応）:
--   030のfinalize_runについて、以下の指摘を実コードで確認した。
--
--   1. snapshotの存在確認: `FROM public.snapshot s, unnest(s.unresolved_items)
--      AS item WHERE s.run_id = p_run_id` は、snapshotが存在しない場合と
--      unresolved_itemsがNULLの場合のいずれもFROM句が0行になり、
--      「空配列（解消済み）」と区別できず count=0 で確定が通ってしまう。
--      snapshotはUNIQUE(run_id)制約があるため複数件は構造的に発生しないが、
--      「0件」「NULL」「空配列」を明示的に区別する検査に是正する。
--
--   2. customer_decision: `IS DISTINCT FROM 'compare'` は、NULL・想定外値も
--      「比較を行わない例外ルート」として扱ってしまう。customer_decisionが
--      未設定（NULL）のrunは、本来どの経路をたどったか確定していない状態で
--      あり、確定を許可すべきではない。許容4値
--      （compare/renewal_no_change/information_refused/comparison_waived）
--      のいずれかが明示的に設定されていることを要求する。
--
--   3. p_pdf_object_key・p_pdf_sha256: 現在アーキテクチャ上、実ファイルの
--      Supabase Storageへのアップロードは行われておらず（`buildMinimalProofStub`
--      によるJSON証跡スタブを `/api/finalize` ルート内でハッシュ化し、
--      同一の信頼された리퀘스트内でfinalize_runへ渡すのみ）、
--      「Storage上の実ファイル存在・内容一致」を検査する対象自体が
--      現状のシステムには存在しない。この点は証跡資料で別途ご説明する。
--      一方、finalize_run自体がp_pdf_object_key・p_pdf_sha256の形式を
--      一切検査しておらず、`/api/finalize`を経由せずRPCを直接呼び出す
--      経路（第3段階で他の項目は塞いだが、この2引数の形式検査は
--      対象外だった）に対しては、NULL・空文字・SHA-256形式でない値・
--      対象run以外のパスをそのまま受け入れてしまう。形式検査を追加する。
--
--   4. 二重確定・同時確定: 現在のUPDATE文には `WHERE id = p_run_id` のみで
--      run_statusの条件がなく、FOUND検査もない。2つの同時呼出しが
--      いずれも同一のrun_status読み取り結果（'draft'等）を得たあとで
--      両方がUPDATEを実行できてしまう（後着ちの値で上書き、
--      run_finalizedイベントが重複記録される）実測未検証だが構造上
--      明確なレースコンディション。`SELECT ... FOR UPDATE` で対象行を
--      関数冒頭でロックし、直列化する。
--
-- 【対応外・別途ご相談】
--   meeting_sceneがNULLの場合、important_matters_deliveredの検査自体が
--   スキップされる点について: meeting_sceneを確定条件として常に必須と
--   すべきか（現状は「面談シーンが設定されている場合のみ重要事項確認を
--   要求する」という設計）は業務方針の判断が必要なため、本migrationでは
--   変更せず、証跡資料で改めてご確認いただく。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.finalize_run(
    p_run_id uuid,
    p_pdf_object_key text,
    p_pdf_sha256 text,
    p_consent_comparison_result boolean DEFAULT false
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
    -- 1. 呼出者の識別（引数を信用せず auth.uid() から解決する）
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'finalize_run: no active operator for the calling session';
    END IF;

    -- 2. 対象runの取得・存在確認・代理店照合。
    --    同時確定・二重確定を防ぐため、この時点で対象行をロックする
    --    （田島様2026-08-01ご指摘: SELECT...FOR UPDATEによる直列化）。
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

    -- 3. run_status（'draft'・'post_record_pending' の両方を許容。G-21準拠）
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'finalize_run: run % not found or not in draft status', p_run_id;
    END IF;

    -- 4. customer_decision: NULL・想定外値を例外ルートとして扱わない
    --    （田島様2026-08-01ご指摘。許容4値のいずれかを明示的に要求する）
    IF v_customer_decision IS NULL
       OR v_customer_decision NOT IN ('compare', 'renewal_no_change', 'information_refused', 'comparison_waived')
    THEN
        RAISE EXCEPTION 'finalize_run: customer_decision is not set to a valid value';
    END IF;
    v_exception_route := (v_customer_decision <> 'compare');

    -- 5. snapshot: 存在確認（0件・NULL・空配列を明示的に区別する）
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

    -- 6. insurer_list_presented の記録確認
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

    -- 7. PDF証跡引数の形式検査（田島様2026-08-01ご指摘。
    --    /api/finalize を経由せずRPCを直接呼び出す経路への対策）
    IF p_pdf_object_key IS NULL OR btrim(p_pdf_object_key) = '' THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key is required';
    END IF;
    IF p_pdf_object_key NOT LIKE ('runs/' || p_run_id::text || '/%') THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key does not belong to this run';
    END IF;
    IF p_pdf_sha256 IS NULL OR p_pdf_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_sha256 is not a valid SHA-256 hex digest';
    END IF;

    -- 8. 確定処理
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
END;
$$;

REVOKE EXECUTE ON FUNCTION public.finalize_run(uuid, text, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.finalize_run(uuid, text, text, boolean) TO authenticated;
