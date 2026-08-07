-- ============================================================================
-- 067_check.sql
--
-- migration 067（service_roleの関数EXECUTE権限を許可リストへ揃えるREVOKE）が
-- 適用済みであることを、第三者が再実行して確認するための読み取り専用SQL。
--
-- 本ファイルはデータを一切変更しない。カタログのみを参照する。
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/067_check.sql
-- 期待する結果: 例外が発生せず、最後に NOTICE が1件出力される。
-- ============================================================================

DO $$
DECLARE
    v_count int;
    v_extra text;
    v_oid   oid;
BEGIN
    -- ── 1. service_roleがEXECUTEできるpublic関数は、許可した2件のみであること ─
    SELECT count(*), string_agg(p.proname, ', ') INTO v_count, v_extra
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND has_function_privilege('service_role', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('record_verified_proof_hash', 'get_proof_object_version');
    IF v_count <> 0 THEN
        RAISE EXCEPTION '067 verify failed: service_role can still EXECUTE % unexpected function(s): %', v_count, v_extra;
    END IF;

    -- ── 2. 検証処理が実際に必要とする2関数のEXECUTEは失われていないこと ─────
    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'record_verified_proof_hash';
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '067 verify failed: service_role lost EXECUTE on record_verified_proof_hash';
    END IF;

    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'get_proof_object_version';
    IF NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '067 verify failed: service_role lost EXECUTE on get_proof_object_version';
    END IF;

    RAISE NOTICE '067 verify passed: service_role can EXECUTE exactly 2 public-schema functions';
END;
$$;
