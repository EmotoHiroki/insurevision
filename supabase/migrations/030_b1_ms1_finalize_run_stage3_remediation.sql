-- ============================================================================
-- 030_b1_ms1_finalize_run_stage3_remediation.sql
--
-- 状態: 本番適用済み
--
-- 背景（第3段階本体。田島様2026-07-27ご指摘1・2026-07-28ご指摘（棚卸し）・
--       2026-07-30ご指摘一連で繰り返し焦点となっていた、本エンゲージメント
--       最大の残課題への対応）:
--
--   017は finalize_run の PUBLIC/anon からの EXECUTE を剥奪し、未認証経路の
--   悪用のみを遮断した。017自身のコメントに明記していたとおり、
--   authenticatedであれば以下がすべて可能な状態が残っていた。
--
--   1. **呼出者詐称**: p_operator_id を引数でそのまま受け取り、run.finalized_by・
--      audit_event.operator_id にそのまま書き込んでいた。呼出者のauth.uid()と
--      一切照合しないため、activeな同一代理店operatorが、任意のoperator_idを
--      名乗って確定・証跡記録を行えた。
--   2. **代理店照合の欠落**: 対象runのagency_idと呼出者のagencyを一切比較して
--      いなかった。activeなoperatorであれば、他代理店のrunも確定できた。
--   3. **search_path未設定**: 021-a-3で修正した2関数と異なり、finalize_runは
--      search_pathを設定していなかった（`run`・`audit_event`も非修飾）。
--   4. **確定条件のDB側迂回**: アプリの `/api/finalize` ルート
--      （`src/app/api/finalize/route.ts`）でのみ、unresolved_items・
--      insurer_list_presented記録・compare_presented_at・
--      important_matters_delivered・post_record phase2完了、を検査していた。
--      RPCを直接呼び出せば、これらのDB側の検査は一切ないため、いずれも
--      迂回できた。
--   5. **`exceptionRoute` がクライアント信用値**: アプリルート自身も、
--      `exceptionRoute` をクライアントのリクエストボディからそのまま信用して
--      おり、サーバー側で `customer_decision` から導出していなかった。
--      本来 `exceptionRoute` の意味は「customer_decisionが'compare'ではない」
--      ことであり（`src/app/run/[id]/page.tsx` のcanNext判定
--      `customer_decision !== 'compare' || ...` と同一の考え方）、これを
--      DB側でrunの実際の値から導出することで、クライアントの申告に
--      依存しない検査にする。
--   6. **run_status のWHERE句が'draft'のみ**: アプリルートは
--      'draft'・'post_record_pending' の両方を確定対象として許容している
--      （G-21）が、finalize_run自体のWHERE句は 'draft' のみを許容しており、
--      post_record_pending からの確定はRPC単体では失敗する状態だった
--      （機能上の不整合。セキュリティとは別の実装不備として同時に修正）。
--
-- 対応:
--   - p_operator_id 引数を廃止し、auth.uid() から呼出者のoperatorを解決する
--     （exclude_candidate・update_candidate_coverage_statusと同一パターン）。
--     is_active=true も検査する。
--   - 対象runのagency_idと呼出者のagencyを照合する（IS DISTINCT FROM）。
--   - search_pathを空文字列にし、run・audit_event・operator・snapshotへの
--     参照をすべて完全修飾する。
--   - run_statusのWHERE句を 'draft'・'post_record_pending' の両方に拡張する。
--   - アプリルートが行っていた確定条件の検査を、関数内に移植する。
--     unresolved_items（snapshotが存在する場合）・insurer_list_presented
--     イベントの存在・compare_presented_at・important_matters_delivered・
--     post_record phase2完了、をすべてDB側で検査する。
--     `exceptionRoute` は引数として受け取らず、`customer_decision`
--     から `customer_decision IS DISTINCT FROM 'compare'` として導出する。
--
-- 対応外（アプリコード側の残課題。本migrationの範囲外）:
--   `src/app/api/finalize/route.ts` の `consentFlags.important_matters`・
--   `personal_info` に基づく2件の追加audit_event挿入は、本migrationの後も
--   引き続きAPIルート側で行われる。ただし `audit_event_insert_own_agency`
--   ポリシー（012/013）の WITH CHECK が `operator_id IS NULL OR operator_id
--   IN (SELECT operator.id FROM operator WHERE operator.auth_user_id =
--   auth.uid())` であるため、クライアントが詐称したoperatorIdでの挿入は
--   既存のRLSにより拒否される。したがって直接の脆弱性verification対象では
--   ないと判断し、本migrationでは変更しない。
--
--   また、`/api/run/[id]/plan-selection` 等、他のAPIルートにもクライアント
--   供給の operatorId をそのまま利用している箇所が複数存在することを
--   確認した。これらは finalize_run と異なりSECURITY DEFINER関数を経由せず
--   RLSの保護下にあるため本migrationの対象外とするが、横展開の観点から
--   別途棚卸しが必要な項目として記録する（今後のタスクへ）。
-- ============================================================================

-- ── 旧シグネチャの関数を明示的に削除する ─────────────────────────────────
-- 新シグネチャ（p_operator_id なし・4引数）を追加するだけでは、PostgreSQLの
-- 関数オーバーロードにより旧シグネチャ（5引数）が引き続き併存・呼出可能な
-- ままになる。旧シグネチャは呼出者詐称という本migrationが解消しようとする
-- 脆弱性そのものであるため、必ず明示的にDROPする。
DROP FUNCTION IF EXISTS public.finalize_run(uuid, text, text, uuid, boolean);

CREATE FUNCTION public.finalize_run(
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

    -- 2. 対象runの取得・存在確認・代理店照合
    SELECT agency_id, run_status, customer_decision, compare_presented_at,
           meeting_scene, important_matters_delivered, recording_mode, post_record_status
      INTO v_run_agency, v_run_status, v_customer_decision, v_compare_presented_at,
           v_meeting_scene, v_important_matters_delivered, v_recording_mode, v_post_record_status
      FROM public.run
     WHERE id = p_run_id;

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

    -- 4. 確定条件（アプリの /api/finalize が行っていた検査をDB側へ移植）
    v_exception_route := (v_customer_decision IS DISTINCT FROM 'compare');

    SELECT count(*) INTO v_unresolved_count
      FROM public.snapshot s, unnest(s.unresolved_items) AS item
     WHERE s.run_id = p_run_id;
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

    -- 5. 確定処理
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
