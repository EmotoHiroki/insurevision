-- ============================================================================
-- 029_check.sql
--
-- migration 029（関数のグローバル既定権限）の検証。
--
-- 田島様2026-07-30ご指摘A-2「022の自己検査はpg_default_aclの格納内容を
-- 見ているだけで、新規オブジェクトへの実効権限は確認できていない」への
-- 対応として、pg_default_aclを読むのではなく、**実際にテーブル・シーケンス・
-- 関数を1件ずつ作成し、生成された実オブジェクトの権限を検証したうえで
-- 削除する**。DDLを含むため、通し適用ツールでは実行されないよう
-- migrations/ ではなくこちらに置く。
-- ============================================================================

DO $$
DECLARE
    v_server_version_num int := current_setting('server_version_num')::int;
    v_bad text;
BEGIN
    -- ── 実オブジェクトを作成する ────────────────────────────────────────
    CREATE TABLE public.zz_029_verify_tbl (id int);
    CREATE SEQUENCE public.zz_029_verify_seq;
    CREATE FUNCTION public.zz_029_verify_fn() RETURNS void LANGUAGE sql AS $body$ SELECT 1 $body$;

    -- ── テーブル: PUBLIC・anon・authenticatedのいずれも無権限であること ──
    SELECT string_agg(role_name, ', ') INTO v_bad
      FROM (VALUES ('public'::name), ('anon'::name), ('authenticated'::name)) AS r(role_name)
     WHERE has_table_privilege(role_name, 'public.zz_029_verify_tbl',
             CASE WHEN v_server_version_num >= 170000
                  THEN 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN'
                  ELSE 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER' END);
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '029 verify failed: table grants privileges to -> %', v_bad;
    END IF;

    -- ── シーケンス: 同様に無権限であること ──────────────────────────────
    SELECT string_agg(role_name, ', ') INTO v_bad
      FROM (VALUES ('public'::name), ('anon'::name), ('authenticated'::name)) AS r(role_name)
     WHERE has_sequence_privilege(role_name, 'public.zz_029_verify_seq', 'USAGE, SELECT, UPDATE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '029 verify failed: sequence grants privileges to -> %', v_bad;
    END IF;

    -- ── 関数: 同様に無権限であること（本migrationが対象とする本体）──────
    SELECT string_agg(role_name, ', ') INTO v_bad
      FROM (VALUES ('public'::name), ('anon'::name), ('authenticated'::name)) AS r(role_name)
     WHERE has_function_privilege(role_name, 'public.zz_029_verify_fn()', 'EXECUTE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '029 verify failed: function grants EXECUTE to -> % (proacl=%)',
          v_bad, (SELECT proacl::text FROM pg_proc WHERE proname='zz_029_verify_fn');
    END IF;

    -- ── 後始末 ──────────────────────────────────────────────────────────
    DROP FUNCTION public.zz_029_verify_fn();
    DROP SEQUENCE public.zz_029_verify_seq;
    DROP TABLE public.zz_029_verify_tbl;

    RAISE NOTICE '029 verify passed: newly created table/sequence/function grant nothing to PUBLIC/anon/authenticated (real objects created and dropped, not just pg_default_acl inspection)';
END $$;
