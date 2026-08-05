-- ============================================================================
-- 057_b1_ms1_proof_server_authored_and_post_finalize_storage_freeze.sql
--
-- 田島様2026-08-06レビューでご指摘いただいた、証跡の完全性に関する3点を是正する。
-- 056までの実装は「DBに登録された本文とStorage上の実体が一致すること」までは
-- 保証していたが、その本文自体が呼出し元の任意入力であり、かつ確定後に
-- 差し替え可能であったため、証跡としての要件を満たしていなかった。
--
-- 【是正1】確定後もStorage上の証跡を上書きできた
--   054のStorage RLS（INSERT/UPDATE）は代理店の所有のみを検査しており、
--   run_statusを見ていなかった。このため確定後であっても、同一代理店の
--   認証済み利用者が runs/{run_id}/proof.json を差し替えることができた。
--   DB側の pdf_sha256 は確定時の値のまま変わらないため、記録されたハッシュと
--   実体が食い違う（＝証跡が無効化される）状態を作れてしまう。
--   → INSERT/UPDATE のポリシーに run_status の許可リストを追加し、
--     確定後・アーカイブ後・保留中は書込み自体を拒否する。
--
-- 【是正2】証跡の本文が呼出し元の任意入力だった
--   056の save_run_proof(p_run_id, p_object_key, p_payload) は、空でなければ
--   任意のテキストを受け付け、それをハッシュ化して保存していた。finalize_run は
--   「登録された本文とStorage上の実体が一致すること」しか検証しないため、
--   利用者が自分のrunに対して事実と異なる内容の証跡を登録・アップロードし、
--   そのまま確定することが可能だった。すなわち「保存物の同一性」は保証しても
--   「内容がrunの実態を反映していること」は保証していなかった。
--   → 本文をDB側が run・snapshot から組み立てる方式へ変更する。
--     呼出し元は本文を渡せない（引数から削除）。オブジェクトキーもDBが決める。
--     同意3種のみ、業務上の申告値として引数で受け取る（監査証跡として
--     audit_event にも記録される値であり、DBが導出できる性質のものではない）。
--
-- 【是正3】Storage実体との内容比較がfail-openだった
--   056は eTag が32桁のMD5形式のときだけ内容比較を行い、eTag が無い場合や
--   形式が異なる場合は比較を飛ばしてsize一致のみで通していた。資料には
--   「内容一致を保証する」と記載しており、実装より強い主張になっていた。
--   → eTag が利用できない場合は確定を拒否する（fail-closed）。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

-- ── 是正1: 確定後のStorage書込みを封じる ─────────────────────────────────
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
           AND r.run_status IN ('draft', 'post_record_pending')
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
           AND r.run_status IN ('draft', 'post_record_pending')
    )
)
WITH CHECK (
    bucket_id = 'proofs'
    AND (storage.foldername(name))[1] = 'runs'
    AND EXISTS (
        SELECT 1 FROM public.run r
         WHERE r.id::text = (storage.foldername(name))[2]
           AND r.agency_id = public.get_my_agency_id()
           AND r.run_status IN ('draft', 'post_record_pending')
    )
);

-- ── 是正2: 証跡本文をDB側で組み立てる ────────────────────────────────────
-- 呼出し元が本文を渡す旧シグネチャは廃止する。
DROP FUNCTION IF EXISTS public.save_run_proof(uuid, text, text);

CREATE OR REPLACE FUNCTION public.save_run_proof(
    p_run_id uuid,
    p_consent_comparison_result boolean DEFAULT false,
    p_consent_important_matters boolean DEFAULT false,
    p_consent_personal_info     boolean DEFAULT false
)
RETURNS TABLE (object_key text, payload text, sha256 text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id uuid;
    v_run         public.run;
    v_snapshot    public.snapshot;
    v_obj         jsonb;
    v_key         text;
    v_payload     text;
    v_sha         text;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'save_run_proof: no active operator for the calling session';
    END IF;

    SELECT * INTO v_run FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run.id IS NULL THEN
        RAISE EXCEPTION 'save_run_proof: run % not found', p_run_id;
    END IF;
    IF v_run.agency_id IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'save_run_proof: run does not belong to caller''s agency';
    END IF;
    IF v_run.run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'save_run_proof: run is %, proof can no longer be registered', v_run.run_status;
    END IF;

    SELECT * INTO v_snapshot FROM public.snapshot WHERE run_id = p_run_id;

    -- 本文はDBが run・snapshot から組み立てる。呼出し元は内容に関与できない。
    -- jsonbはキー順を正規化するため、同一入力に対して常に同一のテキストになる。
    v_obj := jsonb_build_object(
        'run_id',                 v_run.id,
        'customer_ref',           v_run.customer_ref,
        'operator_id',            v_run.operator_id,
        'generated_at',           to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'customer_decision',      v_run.customer_decision,
        'decision_reason',        coalesce(v_run.customer_intent_memo, ''),
        'meeting_scene',          v_run.meeting_scene,
        'recording_mode',         v_run.recording_mode,
        'insurer_list_presented', EXISTS (
            SELECT 1 FROM public.audit_event
             WHERE run_id = p_run_id AND event_type = 'insurer_list_presented'
        ),
        'compare_presented_at',   v_run.compare_presented_at,
        'important_matters_delivered', v_run.important_matters_delivered
    );

    IF v_run.customer_decision = 'comparison_waived' THEN
        v_obj := v_obj || jsonb_build_object(
            'consent_important_matters', p_consent_important_matters,
            'consent_personal_info',     p_consent_personal_info);
    END IF;
    IF v_run.customer_decision = 'compare' THEN
        v_obj := v_obj || jsonb_build_object(
            'consent_comparison_result', p_consent_comparison_result);
    END IF;

    IF v_snapshot.run_id IS NOT NULL THEN
        v_obj := v_obj || jsonb_build_object(
            'confirmed_items',    to_jsonb(coalesce(v_snapshot.confirmed_items, '{}')),
            'supplemented_items', to_jsonb(coalesce(v_snapshot.supplemented_items, '{}')),
            'core_logic_version', v_snapshot.core_logic_version);
    END IF;

    v_key     := 'runs/' || p_run_id::text || '/proof.json';
    v_payload := v_obj::text;
    v_sha     := encode(extensions.digest(v_payload, 'sha256'), 'hex');

    INSERT INTO public.run_proof (run_id, object_key, payload, sha256, created_at, updated_at)
    VALUES (p_run_id, v_key, v_payload, v_sha, now(), now())
    ON CONFLICT (run_id) DO UPDATE
        SET object_key = EXCLUDED.object_key,
            payload    = EXCLUDED.payload,
            sha256     = EXCLUDED.sha256,
            updated_at = now();

    object_key := v_key;
    payload    := v_payload;
    sha256     := v_sha;
    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.save_run_proof(uuid, boolean, boolean, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_run_proof(uuid, boolean, boolean, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_run_proof(uuid, boolean, boolean, boolean) TO authenticated;

-- ── 是正3: Storage実体との内容比較をfail-closedにする ────────────────────
CREATE OR REPLACE FUNCTION public.finalize_run(
    p_run_id uuid,
    p_pdf_object_key text,
    p_pdf_sha256 text,
    p_consent_comparison_result boolean DEFAULT false,
    p_consent_important_matters boolean DEFAULT false,
    p_consent_personal_info boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
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
    v_proof_key                   text;
    v_proof_payload               text;
    v_computed_sha                text;
    v_obj_metadata                jsonb;
    v_etag                        text;
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
        RAISE EXCEPTION 'finalize_run: run is %, finalization is not permitted', v_run_status;
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

    -- 証跡の検証（migration 057）
    --   (1) 本文はDBが組み立てたものを使用する（save_run_proof）
    --   (2) SHA-256はDB側で算出し、申告値と一致することを要求する
    --   (3) Storage上の実体のサイズとeTag（Storageサービスが実バイト列から
    --       書き込む値。呼出し元は偽装できない）と突き合わせる。
    --       eTagが利用できない場合は内容比較ができないため確定を拒否する
    --       （056ではここを読み飛ばしており、資料の主張より弱かった）。
    SELECT object_key, payload INTO v_proof_key, v_proof_payload
      FROM public.run_proof WHERE run_id = p_run_id;

    IF v_proof_payload IS NULL THEN
        RAISE EXCEPTION 'finalize_run: proof payload is not registered for this run (call save_run_proof() before finalizing)';
    END IF;
    IF v_proof_key IS DISTINCT FROM p_pdf_object_key THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key (%) does not match the registered proof object key (%)',
            p_pdf_object_key, v_proof_key;
    END IF;

    v_computed_sha := encode(extensions.digest(v_proof_payload, 'sha256'), 'hex');
    IF v_computed_sha <> p_pdf_sha256 THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_sha256 does not match the SHA-256 computed by the database from the stored proof content';
    END IF;

    SELECT o.metadata INTO v_obj_metadata
      FROM storage.objects o
     WHERE o.bucket_id = 'proofs' AND o.name = p_pdf_object_key;

    IF v_obj_metadata IS NULL THEN
        RAISE EXCEPTION 'finalize_run: proof document not found in storage (upload it to proofs/% before finalizing)', p_pdf_object_key;
    END IF;

    IF (v_obj_metadata->>'size')::bigint IS DISTINCT FROM octet_length(v_proof_payload)::bigint THEN
        RAISE EXCEPTION 'finalize_run: stored proof size (%) does not match the registered proof content (% bytes)',
            v_obj_metadata->>'size', octet_length(v_proof_payload);
    END IF;

    v_etag := btrim(coalesce(v_obj_metadata->>'eTag', ''), '"');
    IF v_etag !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'finalize_run: storage did not record a usable eTag for the proof object, so its byte content cannot be verified (eTag=%)',
            coalesce(v_obj_metadata->>'eTag', '(null)');
    END IF;
    IF v_etag <> md5(v_proof_payload) THEN
        RAISE EXCEPTION 'finalize_run: stored proof content does not match the registered proof content (eTag/MD5 mismatch)';
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
