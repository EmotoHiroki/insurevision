-- ============================================================================
-- 065_check.sql
--
-- migration 065（検証したバイト列と確定対象の実体との結びつきを、
-- MD5に依らず版で担保する是正）が適用済みであることを、
-- 第三者が再実行して確認するための読み取り専用SQL。
--
-- 064では、実体のダウンロード（ロックなし）と版の読み取り（ロックあり）が
-- 別々のタイミングで行われ、その2つが同一の実体を指すことを担保していたのは
-- eTag（MD5）の照合だけであった。065で、版をダウンロードより前に読み、
-- 記録時にその版から変化していないことを要求する形へ改めている。
--
-- 本ファイルはデータを一切変更しない。カタログのみを参照する。
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/065_check.sql
-- 期待する結果: 例外が発生せず、最後に NOTICE が1件出力される。
-- ============================================================================

DO $$
DECLARE
    v_oid  oid;
    v_src  text;
    v_cnt  int;
BEGIN
    -- ── 1. 記録関数は4引数版がちょうど1件だけ存在すること ──────────────────
    -- 旧3引数版が残っていると、版の突き合わせを行わない経路が生き続ける。
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'record_verified_proof_hash';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '065 verify failed: expected exactly 1 record_verified_proof_hash, found %', v_cnt;
    END IF;

    SELECT p.oid, p.prosrc INTO v_oid, v_src FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'record_verified_proof_hash';

    IF (SELECT pronargs FROM pg_proc WHERE oid = v_oid) <> 4 THEN
        RAISE EXCEPTION '065 verify failed: record_verified_proof_hash must take 4 arguments (p_run_id, p_verified_sha256, p_byte_size, p_version_before) but takes %',
            (SELECT pronargs FROM pg_proc WHERE oid = v_oid);
    END IF;

    -- 旧3引数版が存在しないこと（引数型まで指定して確認する）
    IF EXISTS (
        SELECT 1 FROM pg_proc
         WHERE pronamespace = 'public'::regnamespace
           AND proname = 'record_verified_proof_hash'
           AND pg_get_function_identity_arguments(oid)
               = 'p_run_id uuid, p_verified_sha256 text, p_byte_size bigint') THEN
        RAISE EXCEPTION '065 verify failed: the old 3-argument record_verified_proof_hash still exists';
    END IF;

    -- ── 2. 版の突き合わせと行ロックが実装されていること ────────────────────
    IF v_src NOT LIKE '%IS DISTINCT FROM p_version_before%' THEN
        RAISE EXCEPTION '065 verify failed: record_verified_proof_hash does not compare the pre-download version';
    END IF;
    IF v_src NOT LIKE '%WHERE run_id = p_run_id FOR UPDATE%' THEN
        RAISE EXCEPTION '065 verify failed: record_verified_proof_hash does not lock the run_proof row';
    END IF;
    IF v_src NOT LIKE '%FROM storage.objects o%' OR v_src NOT LIKE '%FOR UPDATE%' THEN
        RAISE EXCEPTION '065 verify failed: record_verified_proof_hash does not lock the storage object row';
    END IF;
    -- 多層防御として、サイズとeTagの照合が残っていること
    IF v_src NOT LIKE '%eTag mismatch%' THEN
        RAISE EXCEPTION '065 verify failed: record_verified_proof_hash lost the eTag cross-check';
    END IF;

    -- ── 3. 記録関数は service_role 専用であること ──────────────────────────
    IF (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
        RAISE EXCEPTION '065 verify failed: record_verified_proof_hash must be SECURITY INVOKER (SECURITY DEFINER would make current_user the owner and defeat the caller check)';
    END IF;
    IF v_src NOT LIKE '%current_user <> ''service_role''%' THEN
        RAISE EXCEPTION '065 verify failed: record_verified_proof_hash does not check the calling role';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 verify failed: service_role cannot execute record_verified_proof_hash';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 verify failed: authenticated can execute record_verified_proof_hash';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 verify failed: anon can execute record_verified_proof_hash';
    END IF;

    -- ── 4. 版読み取り関数が存在し、同じく service_role 専用であること ───────
    SELECT p.oid, p.prosrc INTO v_oid, v_src FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'get_proof_object_version';
    IF v_oid IS NULL THEN
        RAISE EXCEPTION '065 verify failed: get_proof_object_version does not exist';
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
        RAISE EXCEPTION '065 verify failed: get_proof_object_version must be SECURITY INVOKER';
    END IF;
    IF v_src NOT LIKE '%current_user <> ''service_role''%' THEN
        RAISE EXCEPTION '065 verify failed: get_proof_object_version does not check the calling role';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 verify failed: service_role cannot execute get_proof_object_version';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '065 verify failed: get_proof_object_version must not be executable by anon or authenticated';
    END IF;

    -- ── 5. 記録関数が依存する storage 側の権限 ─────────────────────────────
    -- storage.objects を FOR UPDATE で読むため、SELECT と UPDATE の両方が要る。
    IF NOT has_schema_privilege('service_role', 'storage', 'USAGE') THEN
        RAISE EXCEPTION '065 verify failed: service_role lacks USAGE on schema storage';
    END IF;
    IF NOT has_table_privilege('service_role', 'storage.objects', 'SELECT')
       OR NOT has_table_privilege('service_role', 'storage.objects', 'UPDATE') THEN
        RAISE EXCEPTION '065 verify failed: service_role cannot lock storage.objects (SELECT and UPDATE are both required for FOR UPDATE)';
    END IF;

    -- ── 6. run_proof は anon・authenticated から到達できないこと ───────────
    IF has_table_privilege('authenticated', 'public.run_proof', 'SELECT')
       OR has_table_privilege('authenticated', 'public.run_proof', 'UPDATE')
       OR has_table_privilege('anon', 'public.run_proof', 'SELECT') THEN
        RAISE EXCEPTION '065 verify failed: run_proof must remain unreachable for anon and authenticated';
    END IF;

    RAISE NOTICE '065 verify passed: the verified hash is bound to the object version read before download, without relying on MD5';
END;
$$;
