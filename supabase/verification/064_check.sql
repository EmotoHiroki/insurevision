-- ============================================================================
-- 064_check.sql
--
-- migration 064（Storage上の実ファイルから算出したSHA-256による確定条件）が
-- 適用済みであることを、第三者が再実行して確認するための読み取り専用SQL。
--
-- 田島様2026-08-06ご指摘2への対応内容を検査する。
--   ・検証結果を保持する列が存在すること
--   ・検証結果を記録する関数が service_role 専用であること
--   ・確定時に、実ファイル由来のSHA-256と実体の版の一致を要求すること
--   ・証跡の再登録・実体の再アップロードで検証結果が無効化されること
--   ・サーバー側処理が必要とする権限が、migrationにより明示されていること
--
-- 本ファイルはデータを一切変更しない。カタログのみを参照する。
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/064_check.sql
-- 期待する結果: 例外が発生せず、最後に NOTICE が1件出力される。
-- ============================================================================

DO $$
DECLARE
    v_oid     oid;
    v_src     text;
    v_missing text;
    v_cnt     int;
BEGIN
    -- ── 1. 検証結果を保持する列 ────────────────────────────────────────────
    SELECT string_agg(c.name, ', ') INTO v_missing
      FROM (VALUES ('verified_sha256'), ('verified_at'),
                   ('verified_object_version'), ('verified_byte_size')) AS c(name)
     WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'run_proof'
           AND column_name = c.name);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION '064 verify failed: run_proof is missing columns -> %', v_missing;
    END IF;

    -- ── 2. 記録関数は service_role 専用であること ──────────────────────────
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'record_verified_proof_hash';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '064 verify failed: expected exactly 1 record_verified_proof_hash, found %', v_cnt;
    END IF;

    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'record_verified_proof_hash';

    -- SECURITY DEFINER にすると current_user が関数所有者になり、
    -- 呼出し元が service_role であることを判定できなくなる。
    IF (SELECT prosecdef FROM pg_proc WHERE oid = v_oid) THEN
        RAISE EXCEPTION '064 verify failed: record_verified_proof_hash must be SECURITY INVOKER';
    END IF;
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '064 verify failed: service_role cannot execute record_verified_proof_hash';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '064 verify failed: authenticated can execute record_verified_proof_hash';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '064 verify failed: anon can execute record_verified_proof_hash';
    END IF;

    -- 呼出し元の判定と、版を自ら読み取ることの両方が実装されていること。
    -- 版を引数で受け取る形にすると、ダウンロードと版取得の間に
    -- 実体が差し替えられる余地が生じる。
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = v_oid;
    IF v_src NOT LIKE '%current_user <> ''service_role''%' THEN
        RAISE EXCEPTION '064 verify failed: record_verified_proof_hash does not check the calling role';
    END IF;
    IF v_src NOT LIKE '%FROM storage.objects o%' OR v_src NOT LIKE '%FOR UPDATE%' THEN
        RAISE EXCEPTION '064 verify failed: record_verified_proof_hash must read the object version itself under a row lock';
    END IF;

    -- ── 3. run_proof は anon・authenticated から到達できないこと ───────────
    IF has_table_privilege('authenticated', 'public.run_proof', 'SELECT')
       OR has_table_privilege('authenticated', 'public.run_proof', 'UPDATE')
       OR has_table_privilege('anon', 'public.run_proof', 'SELECT') THEN
        RAISE EXCEPTION '064 verify failed: run_proof must remain unreachable for anon and authenticated';
    END IF;

    -- ── 4. サーバー側処理に必要な権限がmigrationで明示されていること ────────
    -- 本番はSupabaseの既定権限により保持しているが、
    -- ゼロからの通し適用後のDBでは、これらが無いとサーバー側処理が動かない。
    IF NOT has_schema_privilege('service_role', 'public', 'USAGE') THEN
        RAISE EXCEPTION '064 verify failed: service_role lacks USAGE on schema public';
    END IF;
    IF NOT has_table_privilege('service_role', 'public.run', 'SELECT') THEN
        RAISE EXCEPTION '064 verify failed: service_role cannot read public.run';
    END IF;
    IF NOT has_table_privilege('service_role', 'public.run_proof', 'SELECT')
       OR NOT has_table_privilege('service_role', 'public.run_proof', 'UPDATE') THEN
        RAISE EXCEPTION '064 verify failed: service_role cannot record a verification result';
    END IF;

    -- ── 5. 確定条件 ────────────────────────────────────────────────────────
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'finalize_run';
    IF v_src NOT LIKE '%verified_sha256 IS NULL%' THEN
        RAISE EXCEPTION '064 verify failed: finalize_run does not require a verified SHA-256';
    END IF;
    IF v_src NOT LIKE '%verified_object_version IS DISTINCT FROM v_obj_version%' THEN
        RAISE EXCEPTION '064 verify failed: finalize_run does not compare the stored object version against the verified one';
    END IF;
    IF v_src NOT LIKE '%verified_byte_size IS DISTINCT FROM%' THEN
        RAISE EXCEPTION '064 verify failed: finalize_run does not compare the verified byte size';
    END IF;
    -- 多層防御として、従来のサイズ・eTag照合が残っていること
    IF v_src NOT LIKE '%eTag/MD5 mismatch%' THEN
        RAISE EXCEPTION '064 verify failed: finalize_run lost the eTag/MD5 cross-check';
    END IF;

    -- ── 6. 検証結果の無効化 ────────────────────────────────────────────────
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'save_run_proof';
    IF v_src NOT LIKE '%verified_sha256         = NULL%' THEN
        RAISE EXCEPTION '064 verify failed: save_run_proof does not clear a previous verification';
    END IF;

    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'enforce_proof_object_immutable';
    IF v_src NOT LIKE '%verified_sha256         = NULL%' THEN
        RAISE EXCEPTION '064 verify failed: the storage trigger does not clear a previous verification';
    END IF;
    -- トリガーが実際に storage.objects へ接続されていること
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_proc p ON p.oid = t.tgfoid
         WHERE NOT t.tgisinternal
           AND n.nspname = 'storage' AND c.relname = 'objects'
           AND p.proname = 'enforce_proof_object_immutable') THEN
        RAISE EXCEPTION '064 verify failed: enforce_proof_object_immutable is not attached to storage.objects';
    END IF;

    RAISE NOTICE '064 verify passed: finalization requires a SHA-256 computed from the stored file, and the verification is tied to the stored object version';
END;
$$;
