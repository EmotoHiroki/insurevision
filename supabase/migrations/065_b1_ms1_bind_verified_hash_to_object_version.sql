-- ============================================================================
-- 065_b1_ms1_bind_verified_hash_to_object_version.sql
--
-- migration 064 の是正。
--
-- 【064に残っていた問題】
--   064では次の順序で検証していた。
--     T0: 検証処理がStorageから実体をHTTPでダウンロードし、SHA-256を算出する
--     T1: 記録関数が storage.objects を FOR UPDATE でロックし、版を読み取り、
--         サイズとeTagがDB上の本文と一致することを確認して記録する
--
--   T0とT1の間を直列化するものが無い。したがって記録される組は
--   「T0時点のバイト列から算出したSHA-256」と「T1時点の実体の版」であり、
--   この2つが同一の実体を指すことを保証していたのは、
--   **T1で行うeTag（MD5）の照合だけ**であった。
--
--   すなわち、T0とT1の間に、DB上の本文と同じサイズかつ同じMD5を持つ
--   別内容のファイルへ差し替えられた場合、
--     ・記録されるSHA-256は差し替え前の正しい本文のもの
--     ・記録される版は差し替え後の実体のもの
--   となり、確定時の版照合も通過してしまう。
--   実体は差し替え後のファイルのまま確定されうる。
--
--   064のヘッダーには「MD5は衝突攻撃が現実的であり、SHA-256と同等ではない」と
--   記載しており、その解消が本対応の目的であった。にもかかわらず、
--   算出したバイト列と確定対象の実体を結びつける最後の一点が
--   MD5のままになっていた。設計の誤りである。
--
-- 【是正方針】
--   版（storage.objects.version）を「ダウンロードより前」に読み取り、
--   記録時に「その版から変化していないこと」を要求する。
--   version はアップロードのたびに新しい値になるため、
--   ダウンロード前後で版が同一であれば、その間にアップロードは起きていない。
--   これにより、算出したバイト列と記録する版が同一の実体を指すことを、
--   MD5に依存せずに保証できる。
--
--     T0-  : get_proof_object_version() で版を読む            -> V0
--     T0   : 実体をダウンロードし SHA-256 を算出
--     T1   : record_verified_proof_hash(..., p_version_before := V0)
--            ロックしたうえで現在の版 V1 を読み、V1 = V0 を要求する
--
--   サイズとeTagの照合は多層防御として残す。
--
-- 【あわせて是正する点】
--   ・記録関数が run_proof 行をロックしていなかったため、
--     読み取りから更新までの間に save_run_proof が割り込むと、
--     古い本文に対する検証結果が残りうる状態だった。FOR UPDATE を追加する。
--   ・自己検査が storage スキーマの権限を確認していなかった。
--     記録関数は storage.objects を FOR UPDATE で読むため、
--     これらが無いと新規DBで動作しない。検査に追加する。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

-- ── 1. 検証前に版と対象キーを読むための関数（service_role専用） ────────────
-- 呼出し元がキーを組み立てるのではなく、DBが run_proof に記録している
-- object_key をそのまま返す。検証処理が別のキーを見に行く余地をなくす。
CREATE OR REPLACE FUNCTION public.get_proof_object_version(p_run_id uuid)
RETURNS TABLE (object_key text, object_version text)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $fn$
DECLARE
    v_proof public.run_proof;
BEGIN
    IF current_user <> 'service_role' THEN
        RAISE EXCEPTION 'get_proof_object_version: only the service role may call this (current_user=%)', current_user;
    END IF;

    SELECT * INTO v_proof FROM public.run_proof WHERE run_id = p_run_id;
    IF v_proof.run_id IS NULL THEN
        RAISE EXCEPTION 'get_proof_object_version: no proof registered for run %', p_run_id;
    END IF;

    RETURN QUERY
    SELECT v_proof.object_key, o.version
      FROM storage.objects o
     WHERE o.bucket_id = 'proofs' AND o.name = v_proof.object_key;
END;
$fn$;

REVOKE ALL ON FUNCTION public.get_proof_object_version(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_proof_object_version(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.get_proof_object_version(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_proof_object_version(uuid) TO service_role;

-- ── 2. 記録関数を、検証前の版と突き合わせる形へ ────────────────────────────
CREATE OR REPLACE FUNCTION public.record_verified_proof_hash(
    p_run_id          uuid,
    p_verified_sha256 text,
    p_byte_size       bigint,
    p_version_before  text
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
    IF p_version_before IS NULL OR btrim(p_version_before) = '' THEN
        RAISE EXCEPTION 'record_verified_proof_hash: p_version_before is required; read it with get_proof_object_version() before downloading the object';
    END IF;

    SELECT run_status INTO v_run_status FROM public.run WHERE id = p_run_id;
    IF v_run_status IS NULL THEN
        RAISE EXCEPTION 'record_verified_proof_hash: run % not found', p_run_id;
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'record_verified_proof_hash: run is %, verification is only meaningful before finalization', v_run_status;
    END IF;

    -- run_proof 行もロックする。ロックしないと、読み取りから更新までの間に
    -- save_run_proof が本文を差し替え、古い本文に対する検証結果が残りうる。
    SELECT * INTO v_proof FROM public.run_proof WHERE run_id = p_run_id FOR UPDATE;
    IF v_proof.run_id IS NULL THEN
        RAISE EXCEPTION 'record_verified_proof_hash: no proof registered for run %; call save_run_proof() first', p_run_id;
    END IF;

    IF p_verified_sha256 <> v_proof.sha256 THEN
        RAISE EXCEPTION 'record_verified_proof_hash: SHA-256 computed from the stored file (%) does not match the registered proof content (%)',
            p_verified_sha256, v_proof.sha256;
    END IF;
    IF p_byte_size IS DISTINCT FROM octet_length(v_proof.payload)::bigint THEN
        RAISE EXCEPTION 'record_verified_proof_hash: stored file size (%) does not match the registered proof content (% bytes)',
            p_byte_size, octet_length(v_proof.payload);
    END IF;

    SELECT o.metadata, o.version INTO v_obj_metadata, v_obj_version
      FROM storage.objects o
     WHERE o.bucket_id = 'proofs' AND o.name = v_proof.object_key
     FOR UPDATE;

    IF v_obj_version IS NULL THEN
        RAISE EXCEPTION 'record_verified_proof_hash: proof object % not found in storage, or storage recorded no version', v_proof.object_key;
    END IF;

    -- ここが本migrationの要点。
    -- ダウンロード前に読んだ版と、ロック後に読んだ版が同一であることを要求する。
    -- 版はアップロードのたびに変わるため、両者が一致するならば、
    -- ダウンロードから現在までの間にアップロードは発生していない。
    -- すなわち、算出したSHA-256は「いま記録しようとしている版の実体」の
    -- バイト列から得たものであると言える。MD5には依存しない。
    IF v_obj_version IS DISTINCT FROM p_version_before THEN
        RAISE EXCEPTION 'record_verified_proof_hash: the stored object changed between reading its version and recording the hash (before=%, now=%); verify it again',
            p_version_before, v_obj_version;
    END IF;

    -- 以下は多層防御として残す。上の版照合だけでも同一性は担保される。
    IF (v_obj_metadata->>'size')::bigint IS DISTINCT FROM octet_length(v_proof.payload)::bigint THEN
        RAISE EXCEPTION 'record_verified_proof_hash: the stored object size (%) does not match the registered proof content (% bytes)',
            v_obj_metadata->>'size', octet_length(v_proof.payload);
    END IF;
    v_etag := btrim(coalesce(v_obj_metadata->>'eTag', ''), '"');
    IF v_etag !~ '^[0-9a-f]{32}$' OR v_etag <> md5(v_proof.payload) THEN
        RAISE EXCEPTION 'record_verified_proof_hash: the stored object does not match the registered proof content (eTag mismatch)';
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

-- 旧3引数版（検証前の版を受け取らない形）は残さない。
-- 残すと、版の突き合わせを行わない経路が生き続けることになる。
DROP FUNCTION IF EXISTS public.record_verified_proof_hash(uuid, text, bigint);

REVOKE ALL ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint, text) FROM anon;
REVOKE ALL ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.record_verified_proof_hash(uuid, text, bigint, text) TO service_role;

-- ── 3. 適用結果の自己検査 ──────────────────────────────────────────────────
DO $selfcheck$
DECLARE v_oid oid; v_src text; v_cnt int;
BEGIN
    -- 記録関数は4引数版がちょうど1件だけ存在すること
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'record_verified_proof_hash';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '065 failed: expected exactly 1 record_verified_proof_hash, found %', v_cnt;
    END IF;

    SELECT p.oid, p.prosrc INTO v_oid, v_src FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'record_verified_proof_hash';

    IF (SELECT pronargs FROM pg_proc WHERE oid = v_oid) <> 4 THEN
        RAISE EXCEPTION '065 failed: record_verified_proof_hash must take 4 arguments (the pre-download version among them)';
    END IF;
    IF v_src NOT LIKE '%IS DISTINCT FROM p_version_before%' THEN
        RAISE EXCEPTION '065 failed: record_verified_proof_hash does not compare the pre-download version';
    END IF;
    IF v_src NOT LIKE '%WHERE run_id = p_run_id FOR UPDATE%' THEN
        RAISE EXCEPTION '065 failed: record_verified_proof_hash does not lock the run_proof row';
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
        RAISE EXCEPTION '065 failed: record_verified_proof_hash must stay SECURITY INVOKER';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 failed: record_verified_proof_hash must not be executable by anon or authenticated';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 failed: service_role cannot execute record_verified_proof_hash';
    END IF;

    -- 版読み取り関数も service_role 専用であること
    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'get_proof_object_version';
    IF v_oid IS NULL THEN
        RAISE EXCEPTION '065 failed: get_proof_object_version not created';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 failed: get_proof_object_version must not be executable by anon or authenticated';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 failed: service_role cannot execute get_proof_object_version';
    END IF;

    -- 記録関数が依存する storage 側の権限（064の自己検査では見ていなかった）
    IF NOT has_schema_privilege('service_role', 'storage', 'USAGE') THEN
        RAISE EXCEPTION '065 failed: service_role lacks USAGE on schema storage';
    END IF;
    IF NOT has_table_privilege('service_role', 'storage.objects', 'SELECT')
       OR NOT has_table_privilege('service_role', 'storage.objects', 'UPDATE') THEN
        RAISE EXCEPTION '065 failed: service_role cannot lock storage.objects (SELECT and UPDATE are both required for FOR UPDATE)';
    END IF;

    RAISE NOTICE '065: the verified hash is now bound to the object version, without relying on MD5';
END;
$selfcheck$;
