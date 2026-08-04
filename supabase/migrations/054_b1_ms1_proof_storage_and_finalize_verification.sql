-- ============================================================================
-- 054_b1_ms1_proof_storage_and_finalize_verification.sql
--
-- 背景（田島様2026-08-04ご決定・8月1日ご指摘の再確認）:
--
--   「Storage上の証跡実体の保存とSHA-256一致確認は、MS1で対応してください」
--
--   現行の/api/finalizeは、proof.jsonの内容とSHA-256をメモリ上で生成する
--   のみで、Supabase Storageへの実ファイル保存を一切行っていなかった。
--   finalize_run()もp_pdf_object_key・p_pdf_sha256の**形式**（パターン・
--   桁数）を検査するのみで、その実体がStorage上に存在するかは一切
--   検証していなかった。つまり「実体の無いプルーフ」でも確定できる
--   構造だった。
--
-- 【対応】
--   1. `proofs`という非公開Storageバケットを新設する。
--   2. storage.objectsに対し、`runs/{run_id}/...`のパス配下への
--      アップロードを、そのrunの所属代理店のoperatorのみに許可する
--      RLSポリシーを追加する（読み取りも同様）。
--   3. finalize_run()に、`storage.objects`テーブルを直接照会する検証を
--      追加する: bucket_id='proofs'・name=p_pdf_object_key・
--      user_metadata->>'sha256'=p_pdf_sha256 の行が存在しない場合は
--      確定を拒否する。finalize_run()はSECURITY DEFINER（postgres）で
--      実行されるためstorage.objectsのRLSをバイパスして参照でき、
--      呼出者がどの経路であっても（アプリのAPIルートを経由せず直接RPC
--      を呼んだ場合であっても）この検証を回避できない。
--
--   アプリ側（/api/finalize）は、finalize_run()を呼ぶ前に、生成した
--   proof.jsonを`proofs`バケットの`runs/{runId}/proof.json`へ実際に
--   アップロードし、そのSHA-256を`user_metadata.sha256`として保存する。
-- ============================================================================

-- ── 1. バケット新設（非公開） ────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('proofs', 'proofs', false)
ON CONFLICT (id) DO NOTHING;

-- ── 2. storage.objects RLS: runs/{run_id}/... パスを代理店スコープで制御 ─
DROP POLICY IF EXISTS "proofs_insert_own_agency" ON storage.objects;
CREATE POLICY "proofs_insert_own_agency" ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'proofs'
    AND (storage.foldername(name))[1] = 'runs'
    AND EXISTS (
        SELECT 1 FROM public.run r
         WHERE r.id::text = (storage.foldername(name))[2]
           AND r.agency_id = public.get_my_agency_id()
    )
);

DROP POLICY IF EXISTS "proofs_update_own_agency" ON storage.objects;
CREATE POLICY "proofs_update_own_agency" ON storage.objects
FOR UPDATE TO authenticated
USING (
    bucket_id = 'proofs'
    AND (storage.foldername(name))[1] = 'runs'
    AND EXISTS (
        SELECT 1 FROM public.run r
         WHERE r.id::text = (storage.foldername(name))[2]
           AND r.agency_id = public.get_my_agency_id()
    )
)
WITH CHECK (
    bucket_id = 'proofs'
    AND (storage.foldername(name))[1] = 'runs'
    AND EXISTS (
        SELECT 1 FROM public.run r
         WHERE r.id::text = (storage.foldername(name))[2]
           AND r.agency_id = public.get_my_agency_id()
    )
);

DROP POLICY IF EXISTS "proofs_select_own_agency" ON storage.objects;
CREATE POLICY "proofs_select_own_agency" ON storage.objects
FOR SELECT TO authenticated
USING (
    bucket_id = 'proofs'
    AND (storage.foldername(name))[1] = 'runs'
    AND EXISTS (
        SELECT 1 FROM public.run r
         WHERE r.id::text = (storage.foldername(name))[2]
           AND r.agency_id = public.get_my_agency_id()
    )
);

-- DELETEポリシーは追加しない（確定証跡は削除不可のまま維持する）


-- ── 3. finalize_run(): Storage実体の存在とSHA-256一致を確定条件に追加 ────
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
    v_proof_exists                boolean;
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

    -- 田島様2026-08-04ご決定: Storage上の証跡実体の存在とSHA-256一致を
    -- 確定条件とする。アプリのAPIルートを経由せず直接RPCを呼んだ場合でも
    -- 迂回できない（SECURITY DEFINERとしてRLSをバイパスして参照するため）。
    SELECT EXISTS (
        SELECT 1 FROM storage.objects o
         WHERE o.bucket_id = 'proofs'
           AND o.name = p_pdf_object_key
           AND (o.user_metadata->>'sha256') = p_pdf_sha256
    ) INTO v_proof_exists;
    IF NOT v_proof_exists THEN
        RAISE EXCEPTION 'finalize_run: proof document not found in storage, or its recorded SHA-256 does not match (upload the proof to proofs/% before finalizing)', p_pdf_object_key;
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
