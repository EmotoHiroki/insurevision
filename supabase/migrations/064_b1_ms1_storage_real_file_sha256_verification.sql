-- ============================================================================
-- 064_b1_ms1_storage_real_file_sha256_verification.sql
--
-- 田島様2026-08-06ご指摘2への対応。
--
-- 【ご指摘の内容】
--   「DB上の本文に対するSHA-256とサイズ・eTag照合では、条件を満たすものとは
--     判断できない。信頼できるサーバー側の処理でStorage上の実ファイル
--     （proof.json）を取得し、その実バイト列からSHA-256を算出して、
--     検証済みの値として保存する構成としてほしい。あわせて、検証後から確定までの
--     間に対象ファイルを差し替えられないことを維持してほしい」
--
-- 【従来の実装と、満たせていなかった点】
--   migration 057・058では、確定時に次を検証していた。
--     ・DBが保持する本文から算出したSHA-256
--     ・storage.objects.metadata の size（Storageサービスが実バイト列から記録）
--     ・storage.objects.metadata の eTag（同上。単一アップロードではMD5）
--   sizeとeTagはStorageサービスが実体から書き込む値で、呼出し元は偽装できないため、
--   実体と本文の同一性そのものは担保できていた。しかし
--   「実ファイルを読み出してSHA-256を算出する」処理は存在しておらず、
--   ご指示の構成とは異なっていた。MD5は衝突攻撃が現実的に可能な関数でもある。
--
-- 【本migrationで用意するもの】
--   1. run_proof に検証結果を保持する4列を追加する
--        verified_sha256          実バイト列から算出したSHA-256
--        verified_at              検証実施時刻
--        verified_object_version  検証時点の storage.objects.version
--        verified_byte_size       検証時点の実バイト数
--   2. 検証結果を記録する関数 record_verified_proof_hash() を追加する
--      service_role 専用とし、anon・authenticated からは実行できない
--   3. finalize_run() が、検証済みSHA-256の一致と、
--      検証時点から実体が差し替えられていないことを確定の必須条件とする
--   4. 証跡の再登録・実体の再アップロードが行われたら、
--      それ以前の検証結果を無効化する
--
--   実バイト列の取得とSHA-256の算出そのものは、service_role で動作する
--   サーバー側の処理（Edge Function verify-proof）が担う。
--   本migrationはDB側の受け入れ口と確定条件のみを定義する。
--
-- 【差し替えを防ぐ仕組み】
--   (a) 検証時の storage.objects.version を記録し、確定時に再照合する。
--       version はアップロードのたびに変わるため、差し替えがあれば必ず食い違う。
--   (b) finalize_run() は storage.objects 行を FOR UPDATE でロックしてから
--       照合するため、照合から確定までの間に別トランザクションが割り込めない
--       （migration 058で実装済み）。
--   (c) 実体への書込みが起きた時点で、トリガーが検証結果を消す。
--       これにより「古い検証結果のまま確定する」経路が残らない。
--   (d) 確定後・保留中の書込みは RLS とトリガーが拒否する
--       （migration 057・058で実装済み）。
--
-- 【後方互換性について】
--   本migrationの適用後、検証が済んでいない証跡では確定できなくなる（fail-closed）。
--   これは意図した挙動である。既に確定済みのrunには影響しない。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

-- ── 1. 検証結果を保持する列 ────────────────────────────────────────────────
ALTER TABLE public.run_proof
    ADD COLUMN IF NOT EXISTS verified_sha256         text,
    ADD COLUMN IF NOT EXISTS verified_at             timestamptz,
    ADD COLUMN IF NOT EXISTS verified_object_version text,
    ADD COLUMN IF NOT EXISTS verified_byte_size      bigint;

COMMENT ON COLUMN public.run_proof.verified_sha256 IS
    'Storage上の実ファイルを読み出し、その実バイト列から算出したSHA-256。service_roleのみが記録できる';
COMMENT ON COLUMN public.run_proof.verified_object_version IS
    '検証時点の storage.objects.version。確定時に再照合し、差し替えを検知する';

-- run_proof はポリシー0件のdeny-allであり、anon・authenticated には
-- テーブル権限を一切付与していない。追加列も同じ扱いとする。
REVOKE ALL ON TABLE public.run_proof FROM anon;
REVOKE ALL ON TABLE public.run_proof FROM authenticated;

-- ── 1-b. service_role のスキーマ利用権限 ───────────────────────────────────
-- 【本migrationで判明した再現性の欠落】
--   migration 059は `GRANT USAGE ON SCHEMA public` を anon・authenticated には
--   付与していたが、service_role には付与していなかった。
--   本番はプロジェクト作成時の初期設定により service_role が USAGE を保持しているため
--   顕在化しなかったが、`DROP SCHEMA public CASCADE` を経てゼロから通し適用した
--   DBでは service_role が public スキーマを利用できない状態になる。
--   実際、本migrationが追加する service_role 専用関数を新規DBで実行したところ
--   「permission denied for schema public」で失敗した。
--
--   サーバー側処理（本migrationの検証処理を含む）は service_role で動作するため、
--   これは「migration一式だけでは本番と同じ状態を再現できない」ことを意味する。
--   田島様ご指摘3の趣旨に照らして、ここで明示的に付与する。
--   なお service_role はサーバー側でのみ用いる鍵であり、
--   anon・authenticated の到達範囲は変わらない。
GRANT USAGE ON SCHEMA public TO service_role;

-- あわせて、サーバー側処理が必要とするテーブル権限を明示的に付与する。
-- 本番には service_role 向けのテーブル権限が126件存在するが、これはSupabaseの
-- 既定権限による自動付与であり、どのmigrationにも記録が無い。
-- ゼロからの通し適用後は0件であるため、本番では動く処理が新規DBでは動かない。
-- 059で定めた「必要なものだけを明示的に許可する」方針に従い、
-- 126件を機械的に再現するのではなく、検証処理が実際に必要とする2表のみを付与する。
--   public.run       … 対象runの状態確認（読取りのみ）
--   public.run_proof … 登録済み証跡の参照と、検証結果の記録
GRANT SELECT         ON TABLE public.run       TO service_role;
GRANT SELECT, UPDATE ON TABLE public.run_proof TO service_role;

-- ── 2. 検証結果を記録する関数（service_role専用） ──────────────────────────
-- SECURITY INVOKER とすることで、current_user が実際の呼出しロールになる。
-- SECURITY DEFINER にすると current_user が関数所有者になり、
-- 呼出し元の判定ができなくなるため、意図的に INVOKER としている。
--
-- 3重の防御になっている。
--   ・EXECUTE権限を service_role にのみ付与する
--   ・関数内で current_user を検査する
--   ・run_proof へのテーブル権限が service_role にしかない
-- したがって、仮に呼出し口が漏れても authenticated からは書き込めない。
-- 版（storage.objects.version）は引数で受け取らず、本関数が自ら読み取る。
-- 呼出し元が「ダウンロード後に版を読む」形にすると、その2操作の間に
-- 実体が差し替えられた場合、古いバイト列のハッシュと新しい版の組合せが
-- 記録されうる。本関数は storage.objects 行を FOR UPDATE でロックしたうえで、
-- 版の読取りと、実体が現在のDB本文と一致することの確認を同一トランザクションで行う。
CREATE OR REPLACE FUNCTION public.record_verified_proof_hash(
    p_run_id          uuid,
    p_verified_sha256 text,
    p_byte_size       bigint
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $fn$
DECLARE
    v_proof        public.run_proof;
    v_run_status   text;
    v_obj_metadata jsonb;
    v_obj_version  text;
    v_etag         text;
BEGIN
    IF current_user <> 'service_role' THEN
        RAISE EXCEPTION 'record_verified_proof_hash: only the service role may record a verification result (current_user=%)', current_user;
    END IF;

    IF p_verified_sha256 IS NULL OR p_verified_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'record_verified_proof_hash: p_verified_sha256 must be a lowercase hex SHA-256 (got %)', coalesce(p_verified_sha256, '<NULL>');
    END IF;
    IF p_byte_size IS NULL OR p_byte_size < 0 THEN
        RAISE EXCEPTION 'record_verified_proof_hash: p_byte_size must be a non-negative integer';
    END IF;

    SELECT run_status INTO v_run_status FROM public.run WHERE id = p_run_id;
    IF v_run_status IS NULL THEN
        RAISE EXCEPTION 'record_verified_proof_hash: run % not found', p_run_id;
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'record_verified_proof_hash: run is %, verification is only meaningful before finalization', v_run_status;
    END IF;

    SELECT * INTO v_proof FROM public.run_proof WHERE run_id = p_run_id;
    IF v_proof.run_id IS NULL THEN
        RAISE EXCEPTION 'record_verified_proof_hash: no proof registered for run %; call save_run_proof() first', p_run_id;
    END IF;

    -- 実体から算出した値がDB上の本文と一致しない場合は、記録せずに拒否する。
    -- 記録しなければ確定条件を満たさないため、いずれにせよ確定はできないが、
    -- ここで拒否した方が原因が明確になる。
    IF p_verified_sha256 <> v_proof.sha256 THEN
        RAISE EXCEPTION 'record_verified_proof_hash: SHA-256 computed from the stored file (%) does not match the registered proof content (%)',
            p_verified_sha256, v_proof.sha256;
    END IF;
    IF p_byte_size IS DISTINCT FROM octet_length(v_proof.payload)::bigint THEN
        RAISE EXCEPTION 'record_verified_proof_hash: stored file size (%) does not match the registered proof content (% bytes)',
            p_byte_size, octet_length(v_proof.payload);
    END IF;

    -- 実体の行をロックし、版と付随情報を読み取る。
    -- ロックにより、以降の照合と記録の間に差し替えが割り込むことはできない。
    SELECT o.metadata, o.version INTO v_obj_metadata, v_obj_version
      FROM storage.objects o
     WHERE o.bucket_id = 'proofs' AND o.name = v_proof.object_key
     FOR UPDATE;

    IF v_obj_version IS NULL THEN
        RAISE EXCEPTION 'record_verified_proof_hash: proof object % not found in storage, or storage recorded no version', v_proof.object_key;
    END IF;

    -- ロック取得時点の実体が、DB上の本文と一致していることを確認する。
    -- ここを通れば、記録する版は「本文と一致する実体」の版であることになる。
    -- 以後に差し替えが起きれば版が変わり、確定時の照合で検知される。
    IF (v_obj_metadata->>'size')::bigint IS DISTINCT FROM octet_length(v_proof.payload)::bigint THEN
        RAISE EXCEPTION 'record_verified_proof_hash: the stored object size (%) no longer matches the registered proof content (% bytes)',
            v_obj_metadata->>'size', octet_length(v_proof.payload);
    END IF;
    v_etag := btrim(coalesce(v_obj_metadata->>'eTag', ''), '"');
    IF v_etag !~ '^[0-9a-f]{32}$' OR v_etag <> md5(v_proof.payload) THEN
        RAISE EXCEPTION 'record_verified_proof_hash: the stored object no longer matches the registered proof content (eTag mismatch)';
    END IF;

    UPDATE public.run_proof
       SET verified_sha256         = p_verified_sha256,
           verified_at             = now(),
           verified_object_version = v_obj_version,
           verified_byte_size      = p_byte_size,
           updated_at              = now()
     WHERE run_id = p_run_id;

    RETURN v_obj_version;
END;
$fn$;

-- 旧4引数版（版を引数で受け取る形）が残らないよう明示的に削除する。
DROP FUNCTION IF EXISTS public.record_verified_proof_hash(uuid, text, text, bigint);

REVOKE ALL ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint) FROM anon;
REVOKE ALL ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint) TO service_role;

-- ── 3. 証跡の再登録で検証結果を無効化する ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.save_run_proof(p_run_id uuid, p_consent_comparison_result boolean DEFAULT false, p_consent_important_matters boolean DEFAULT false, p_consent_personal_info boolean DEFAULT false)
 RETURNS TABLE(object_key text, payload text, sha256 text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
            updated_at = now(),
            -- 証跡を登録し直したら本文が変わりうるため、以前の検証結果は無効になる。
            -- 残したままにすると、古い検証結果のまま確定できてしまう。
            verified_sha256         = NULL,
            verified_at             = NULL,
            verified_object_version = NULL,
            verified_byte_size      = NULL;

    object_key := v_key;
    payload    := v_payload;
    sha256     := v_sha;
    RETURN NEXT;
END;
$function$
;

-- ── 4. 実体の再アップロードで検証結果を無効化する ──────────
CREATE OR REPLACE FUNCTION public.enforce_proof_object_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

    -- 実体が書き換わった以上、それ以前の検証結果は別の対象に対するものになる。
    -- ここで消すことで、確定は必ず「現在の実体に対する検証」を要求する。
    UPDATE public.run_proof
       SET verified_sha256         = NULL,
           verified_at             = NULL,
           verified_object_version = NULL,
           verified_byte_size      = NULL
     WHERE run_id = v_run_id
       AND verified_sha256 IS NOT NULL;

    RETURN NEW;
END;
$function$
;

-- ── 5. 確定条件に、実ファイル由来のSHA-256と版の不変を加える ────
CREATE OR REPLACE FUNCTION public.finalize_run(p_run_id uuid, p_pdf_object_key text, p_pdf_sha256 text, p_consent_comparison_result boolean DEFAULT false, p_consent_important_matters boolean DEFAULT false, p_consent_personal_info boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    v_obj_version                 text;
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
    SELECT o.metadata, o.version INTO v_obj_metadata, v_obj_version
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

    -- ── 田島様2026-08-06ご指摘2: 実ファイルのバイト列から算出したSHA-256の照合 ──
    -- サイズとeTag(MD5)の照合は残したうえで（多層防御）、
    -- 「Storage上の実体を実際に読み出して算出したSHA-256」を確定の必須条件とする。
    -- 算出は service_role で動作する検証処理が行い、本関数はその記録を検査する。
    -- 検証が行われていなければ確定を拒否する（fail-closed）。
    IF v_proof.verified_sha256 IS NULL THEN
        RAISE EXCEPTION 'finalize_run: the stored proof has not been verified from its actual bytes yet; run the proof verification before finalizing';
    END IF;
    IF v_proof.verified_sha256 <> v_computed_sha THEN
        RAISE EXCEPTION 'finalize_run: SHA-256 computed from the stored file (%) does not match the SHA-256 of the registered proof content (%)',
            v_proof.verified_sha256, v_computed_sha;
    END IF;
    IF v_proof.verified_byte_size IS DISTINCT FROM octet_length(v_proof.payload)::bigint THEN
        RAISE EXCEPTION 'finalize_run: verified byte size (%) does not match the registered proof content (% bytes)',
            v_proof.verified_byte_size, octet_length(v_proof.payload);
    END IF;

    -- 検証時点と確定時点で、Storage上の実体が同一であることを要求する。
    -- version はアップロードのたびに変わるため、検証後に差し替えが行われていれば
    -- 必ず食い違う。storage.objects行は上で FOR UPDATE によりロック済みであるため、
    -- この照合から確定までの間に別トランザクションが割り込む余地はない。
    IF v_obj_version IS NULL THEN
        RAISE EXCEPTION 'finalize_run: storage did not record a version for the proof object, so the verified result cannot be tied to the stored file';
    END IF;
    IF v_proof.verified_object_version IS DISTINCT FROM v_obj_version THEN
        RAISE EXCEPTION 'finalize_run: the stored proof was replaced after it was verified (verified version %, current version %); verify it again before finalizing',
            coalesce(v_proof.verified_object_version, '(none)'), v_obj_version;
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
$function$
;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE v_src text; v_oid oid; v_missing text;
BEGIN
    -- 1. 列が揃っていること
    SELECT string_agg(c.name, ', ') INTO v_missing
      FROM (VALUES ('verified_sha256'), ('verified_at'),
                   ('verified_object_version'), ('verified_byte_size')) AS c(name)
     WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='public' AND table_name='run_proof' AND column_name=c.name);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION '064 failed: run_proof is missing columns: %', v_missing;
    END IF;

    -- 2. 記録関数が service_role 専用であること
    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='record_verified_proof_hash';
    IF v_oid IS NULL THEN
        RAISE EXCEPTION '064 failed: record_verified_proof_hash not created';
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid=v_oid) THEN
        RAISE EXCEPTION '064 failed: record_verified_proof_hash must be SECURITY INVOKER so that current_user identifies the caller';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '064 failed: service_role cannot execute record_verified_proof_hash';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '064 failed: authenticated can execute record_verified_proof_hash';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '064 failed: anon can execute record_verified_proof_hash';
    END IF;
    -- 版を呼出し元から受け取る旧形式が残っていないこと。
    -- 残っていると、ダウンロードと版取得の間に差し替えが入る余地が生じる。
    IF (SELECT count(*) FROM pg_proc
         WHERE pronamespace='public'::regnamespace
           AND proname='record_verified_proof_hash') <> 1 THEN
        RAISE EXCEPTION '064 failed: expected exactly 1 record_verified_proof_hash overload, found %',
            (SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='record_verified_proof_hash');
    END IF;
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = v_oid;
    IF v_src NOT LIKE '%FROM storage.objects o%' OR v_src NOT LIKE '%FOR UPDATE%' THEN
        RAISE EXCEPTION '064 failed: record_verified_proof_hash must read the object version itself under a row lock';
    END IF;

    -- 2-b. service_role が検証処理に必要な権限を持つこと
    -- （これらが無いと、サーバー側処理が新規DBで一切動かない）
    IF NOT has_schema_privilege('service_role', 'public', 'USAGE') THEN
        RAISE EXCEPTION '064 failed: service_role lacks USAGE on schema public';
    END IF;
    IF NOT has_table_privilege('service_role', 'public.run', 'SELECT') THEN
        RAISE EXCEPTION '064 failed: service_role cannot read public.run';
    END IF;
    IF NOT has_table_privilege('service_role', 'public.run_proof', 'SELECT')
       OR NOT has_table_privilege('service_role', 'public.run_proof', 'UPDATE') THEN
        RAISE EXCEPTION '064 failed: service_role cannot record a verification result on public.run_proof';
    END IF;

    -- 3. authenticated / anon が run_proof へ到達できないこと
    IF has_table_privilege('authenticated', 'public.run_proof', 'SELECT')
       OR has_table_privilege('authenticated', 'public.run_proof', 'UPDATE')
       OR has_table_privilege('anon', 'public.run_proof', 'SELECT') THEN
        RAISE EXCEPTION '064 failed: run_proof must remain unreachable for anon and authenticated';
    END IF;

    -- 4. finalize_run が検証済みSHA-256と版の一致を要求すること
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='finalize_run';
    IF v_src NOT LIKE '%verified_sha256 IS NULL%' THEN
        RAISE EXCEPTION '064 failed: finalize_run does not require a verified SHA-256';
    END IF;
    IF v_src NOT LIKE '%verified_object_version IS DISTINCT FROM v_obj_version%' THEN
        RAISE EXCEPTION '064 failed: finalize_run does not compare the stored object version against the verified one';
    END IF;
    -- 多層防御として、従来のサイズ・eTag照合が残っていること
    IF v_src NOT LIKE '%eTag/MD5 mismatch%' THEN
        RAISE EXCEPTION '064 failed: finalize_run lost the eTag/MD5 cross-check';
    END IF;

    -- 5. 再登録・再アップロードで検証結果が無効化されること
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='save_run_proof';
    IF v_src NOT LIKE '%verified_sha256         = NULL%' THEN
        RAISE EXCEPTION '064 failed: save_run_proof does not clear a previous verification';
    END IF;
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='enforce_proof_object_immutable';
    IF v_src NOT LIKE '%verified_sha256         = NULL%' THEN
        RAISE EXCEPTION '064 failed: the storage trigger does not clear a previous verification';
    END IF;

    RAISE NOTICE '064: finalization now requires a SHA-256 computed from the stored file itself';
END;
$selfcheck$;
