-- ============================================================================
-- 058_b1_ms1_proof_rebuild_on_finalize_and_storage_row_lock.sql
--
-- 田島様2026-08-06 2回目レビューでご指摘いただいた、証跡の完全性に関する
-- 残り3点を是正する。057は「登録時点の本文」と「Storage上の実体」の一致までは
-- 保証していたが、登録から確定までの間に状態が変わる場合と、確定処理と
-- アップロードが並行する場合を塞げていなかった。
--
-- 【是正1】確定処理とアップロードの競合（確定後に上書きが成立しうる）
--   057はStorageのRLSに run_status の許可リストを追加したが、この判定は
--   UPDATE開始時のスナップショットで評価される。finalize_run() は
--   storage.objects の行を一切ロックしないため、runがdraftの時点で認可された
--   アップロードが、finalize_run() のCOMMIT後にCOMMITされる余地が残っていた。
--   結果として「確定済みなのに証跡バイト列が差し替わっている」状態を作れる。
--   → (a) finalize_run() が対象の storage.objects 行を FOR UPDATE でロックし、
--         並行するアップロードと直列化する。
--      (b) storage.objects に BEFORE INSERT/UPDATE トリガーを追加し、
--         書込みの実行時点で親runの状態を再判定する。RLSのスナップショット
--         評価に依存せず、ロック解放後に再開した書込みも確実に拒否できる。
--
-- 【是正2】登録から確定までの間に証跡が陳腐化する
--   save_run_proof() と finalize_run() は別トランザクションであり、その間に
--   draft状態での正当な変更（候補の増減、比較提示のやり直し等）が起こりうる。
--   057の finalize_run() は「登録済み本文とStorage実体の一致」しか見ておらず、
--   確定時点のrun/snapshotから本文を組み立て直して突き合わせていなかったため、
--   古い状態を記録した証跡のまま確定できた。
--   → 本文の組立てを build_run_proof_payload() へ切り出し、finalize_run() が
--     確定時点のロック済みrun/snapshotから本文を再構築して、登録済み本文と
--     一致することを要求する。一致しない場合は確定を拒否し、再登録を促す。
--     再構築の再現性のため、生成時刻と同意3種を run_proof に保存する。
--
-- 【是正3】同意3種が2つのRPCへ別々に渡され、食い違いうる
--   save_run_proof()（証跡本文へ記録）と finalize_run()（audit_eventへ記録）が
--   それぞれ独立に同意フラグを受け取っていたため、証跡の記載と監査ログが
--   異なる値になる余地があった。
--   → finalize_run() は run_proof に保存された同意3種を正とし、引数で渡された
--     値が異なる場合は確定を拒否する。audit_eventも保存された値で記録する。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

-- ── 再構築のための保存項目を追加 ─────────────────────────────────────────
ALTER TABLE public.run_proof
    ADD COLUMN IF NOT EXISTS generated_at                timestamptz,
    ADD COLUMN IF NOT EXISTS consent_comparison_result   boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS consent_important_matters   boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS consent_personal_info       boolean NOT NULL DEFAULT false;

-- ── 本文の組立てを単一の関数に集約する ───────────────────────────────────
-- save_run_proof（登録時）と finalize_run（確定時の再構築）が同一の実装を
-- 使うことで、「登録時と確定時で組立て方が違う」ことによる誤検知・見落としを
-- 構造的に防ぐ。
CREATE OR REPLACE FUNCTION public.build_run_proof_payload(
    p_run_id uuid,
    p_consent_comparison_result boolean,
    p_consent_important_matters boolean,
    p_consent_personal_info     boolean,
    p_generated_at              timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_run      public.run;
    v_snapshot public.snapshot;
    v_obj      jsonb;
BEGIN
    SELECT * INTO v_run FROM public.run WHERE id = p_run_id;
    IF v_run.id IS NULL THEN
        RAISE EXCEPTION 'build_run_proof_payload: run % not found', p_run_id;
    END IF;
    SELECT * INTO v_snapshot FROM public.snapshot WHERE run_id = p_run_id;

    v_obj := jsonb_build_object(
        'run_id',                 v_run.id,
        'customer_ref',           v_run.customer_ref,
        'operator_id',            v_run.operator_id,
        'generated_at',           to_char(p_generated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
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

    RETURN v_obj::text;
END;
$$;

REVOKE ALL ON FUNCTION public.build_run_proof_payload(uuid, boolean, boolean, boolean, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.build_run_proof_payload(uuid, boolean, boolean, boolean, timestamptz) FROM anon;
REVOKE ALL ON FUNCTION public.build_run_proof_payload(uuid, boolean, boolean, boolean, timestamptz) FROM authenticated;

-- ── save_run_proof: 生成時刻と同意3種も保存する ──────────────────────────
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
    v_run_agency  uuid;
    v_run_status  text;
    v_now         timestamptz := now();
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

    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'save_run_proof: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'save_run_proof: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'save_run_proof: run is %, proof can no longer be registered', v_run_status;
    END IF;

    v_key     := 'runs/' || p_run_id::text || '/proof.json';
    v_payload := public.build_run_proof_payload(
                     p_run_id, p_consent_comparison_result,
                     p_consent_important_matters, p_consent_personal_info, v_now);
    v_sha     := encode(extensions.digest(v_payload, 'sha256'), 'hex');

    INSERT INTO public.run_proof (run_id, object_key, payload, sha256, generated_at,
                                  consent_comparison_result, consent_important_matters,
                                  consent_personal_info, created_at, updated_at)
    VALUES (p_run_id, v_key, v_payload, v_sha, v_now,
            p_consent_comparison_result, p_consent_important_matters,
            p_consent_personal_info, now(), now())
    ON CONFLICT (run_id) DO UPDATE
        SET object_key = EXCLUDED.object_key,
            payload    = EXCLUDED.payload,
            sha256     = EXCLUDED.sha256,
            generated_at = EXCLUDED.generated_at,
            consent_comparison_result = EXCLUDED.consent_comparison_result,
            consent_important_matters = EXCLUDED.consent_important_matters,
            consent_personal_info     = EXCLUDED.consent_personal_info,
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

-- ── 是正1(b): Storage書込みの実行時点で親runの状態を再判定する ───────────
-- RLSのUSING/WITH CHECKはUPDATE開始時のスナップショットで評価されるため、
-- 確定処理と競合した場合に「認可時点ではdraft、COMMIT時点では確定済み」という
-- 書込みを許してしまう。トリガーは書込みの実行時点（行ロック取得後）に
-- あらためて親runを参照するため、この経路を確実に塞げる。
CREATE OR REPLACE FUNCTION public.enforce_proof_object_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_run_id     uuid;
    v_run_status text;
BEGIN
    IF NEW.bucket_id IS DISTINCT FROM 'proofs' THEN
        RETURN NEW;
    END IF;
    IF (storage.foldername(NEW.name))[1] IS DISTINCT FROM 'runs' THEN
        RETURN NEW;
    END IF;

    BEGIN
        v_run_id := ((storage.foldername(NEW.name))[2])::uuid;
    EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'proofs: object path does not contain a valid run id (%)', NEW.name;
    END;

    SELECT run_status INTO v_run_status FROM public.run WHERE id = v_run_id;
    IF v_run_status IS NULL THEN
        RAISE EXCEPTION 'proofs: run % not found for object %', v_run_id, NEW.name;
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'proofs: run % is %, the proof object can no longer be created or modified',
            v_run_id, v_run_status;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_proof_object_immutable ON storage.objects;
CREATE TRIGGER trg_proof_object_immutable
    BEFORE INSERT OR UPDATE ON storage.objects
    FOR EACH ROW EXECUTE FUNCTION public.enforce_proof_object_immutable();

-- ── finalize_run: 確定時点で本文を再構築し、Storage行をロックする ────────
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
    v_proof                       public.run_proof;
    v_rebuilt                     text;
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

    SELECT * INTO v_proof FROM public.run_proof WHERE run_id = p_run_id;
    IF v_proof.run_id IS NULL THEN
        RAISE EXCEPTION 'finalize_run: proof payload is not registered for this run (call save_run_proof() before finalizing)';
    END IF;
    IF v_proof.object_key IS DISTINCT FROM p_pdf_object_key THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key (%) does not match the registered proof object key (%)',
            p_pdf_object_key, v_proof.object_key;
    END IF;

    -- 是正3: 同意3種は登録済みの値を正とし、引数との食い違いを許さない。
    IF p_consent_comparison_result IS DISTINCT FROM v_proof.consent_comparison_result
       OR p_consent_important_matters IS DISTINCT FROM v_proof.consent_important_matters
       OR p_consent_personal_info     IS DISTINCT FROM v_proof.consent_personal_info
    THEN
        RAISE EXCEPTION 'finalize_run: consent flags differ from those recorded in the proof; re-register the proof with save_run_proof()';
    END IF;

    -- 是正2: 確定時点のrun/snapshotから本文を再構築し、登録済み本文と一致する
    -- ことを要求する。登録後に状態が変わっている場合はここで検出される。
    v_rebuilt := public.build_run_proof_payload(
                     p_run_id, v_proof.consent_comparison_result,
                     v_proof.consent_important_matters, v_proof.consent_personal_info,
                     v_proof.generated_at);
    IF v_rebuilt IS DISTINCT FROM v_proof.payload THEN
        RAISE EXCEPTION 'finalize_run: the run has changed since the proof was registered; call save_run_proof() again before finalizing';
    END IF;

    v_computed_sha := encode(extensions.digest(v_proof.payload, 'sha256'), 'hex');
    IF v_computed_sha <> p_pdf_sha256 THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_sha256 does not match the SHA-256 computed by the database from the stored proof content';
    END IF;

    -- 是正1(a): 対象のstorage.objects行をロックし、並行するアップロードと
    -- 直列化する。ロックを取得できた時点の最新内容で以降の検証を行う。
    SELECT o.metadata INTO v_obj_metadata
      FROM storage.objects o
     WHERE o.bucket_id = 'proofs' AND o.name = p_pdf_object_key
     FOR UPDATE;

    IF v_obj_metadata IS NULL THEN
        RAISE EXCEPTION 'finalize_run: proof document not found in storage (upload it to proofs/% before finalizing)', p_pdf_object_key;
    END IF;
    IF (v_obj_metadata->>'size')::bigint IS DISTINCT FROM octet_length(v_proof.payload)::bigint THEN
        RAISE EXCEPTION 'finalize_run: stored proof size (%) does not match the registered proof content (% bytes)',
            v_obj_metadata->>'size', octet_length(v_proof.payload);
    END IF;

    v_etag := btrim(coalesce(v_obj_metadata->>'eTag', ''), '"');
    IF v_etag !~ '^[0-9a-f]{32}$' THEN
        RAISE EXCEPTION 'finalize_run: storage did not record a usable eTag for the proof object, so its byte content cannot be verified (eTag=%)',
            coalesce(v_obj_metadata->>'eTag', '(null)');
    END IF;
    IF v_etag <> md5(v_proof.payload) THEN
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

    -- 監査ログも登録済みの同意値で記録する（証跡の記載と必ず一致させる）。
    IF v_proof.consent_comparison_result THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_comparison_result', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;
    IF v_proof.consent_important_matters THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_important_matters', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;
    IF v_proof.consent_personal_info THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_personal_info', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;
END;
$$;
