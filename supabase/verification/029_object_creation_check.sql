-- ============================================================================
-- 029_object_creation_check.sql  【分離検証環境専用・本番では実行しないこと】
--
-- 【重要】本ファイルはテーブル・シーケンス・関数を実際に CREATE し、
--   検査後に DROP する。読み取り専用ではない。
--   田島様2026-08-04ご指示のとおり、分離した検証用プロジェクトの
--   使い捨てデータに対してのみ実行すること。
--   本番用の `run_all_checks.sh` は本ファイルを実行しない。
--
-- 【本ファイルの位置づけ】
--   田島様2026-07-30ご指摘A-2「022の自己検査は pg_default_acl の格納内容を
--   見ているだけで、新規オブジェクトへの実効権限は確認できていない」への対応。
--   カタログ上の設定ではなく、**実際に生成されたオブジェクトの実効権限**を
--   確認することが目的である。
--
--   カタログ参照のみで完結する検査は `029_check.sql`（本番でも実行可）にある。
--
-- 【service_role について】
--   2026-08-09時点では、`postgres` 所有・スキーマ `public` の既定権限により
--   新規オブジェクトへ `service_role` の権限が自動付与される。
--   これは田島様2026-08-08ご指摘3として整理中の事項であり、
--   既定権限の是正がご承認・適用されるまでは付与された状態が正である。
--   そのため本ファイルでは service_role を**失敗条件とはせず、実測値を
--   NOTICE で報告する**にとどめる。是正適用後に失敗条件へ切り替える。
--
-- 実行方法（検証環境のみ）:
--   psql "<検証環境の接続文字列>" -f supabase/verification/029_object_creation_check.sql
-- 期待する結果: 例外が発生せず、NOTICE が出力される。
-- ============================================================================

DO $$
DECLARE
    v_server_version_num int := current_setting('server_version_num')::int;
    v_bad text;
    v_svc text;
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
        DROP FUNCTION public.zz_029_verify_fn();
        DROP SEQUENCE public.zz_029_verify_seq;
        DROP TABLE public.zz_029_verify_tbl;
        RAISE EXCEPTION '029 object-creation verify failed: table grants privileges to -> %', v_bad;
    END IF;

    -- ── シーケンス: 同様に無権限であること ──────────────────────────────
    SELECT string_agg(role_name, ', ') INTO v_bad
      FROM (VALUES ('public'::name), ('anon'::name), ('authenticated'::name)) AS r(role_name)
     WHERE has_sequence_privilege(role_name, 'public.zz_029_verify_seq', 'USAGE, SELECT, UPDATE');
    IF v_bad IS NOT NULL THEN
        DROP FUNCTION public.zz_029_verify_fn();
        DROP SEQUENCE public.zz_029_verify_seq;
        DROP TABLE public.zz_029_verify_tbl;
        RAISE EXCEPTION '029 object-creation verify failed: sequence grants privileges to -> %', v_bad;
    END IF;

    -- ── 関数: 同様に無権限であること（migration 029 の本体）──────────────
    SELECT string_agg(role_name, ', ') INTO v_bad
      FROM (VALUES ('public'::name), ('anon'::name), ('authenticated'::name)) AS r(role_name)
     WHERE has_function_privilege(role_name, 'public.zz_029_verify_fn()', 'EXECUTE');
    IF v_bad IS NOT NULL THEN
        DROP FUNCTION public.zz_029_verify_fn();
        DROP SEQUENCE public.zz_029_verify_seq;
        DROP TABLE public.zz_029_verify_tbl;
        RAISE EXCEPTION '029 object-creation verify failed: function grants EXECUTE to -> %', v_bad;
    END IF;

    -- ── service_role の実測（報告のみ。上記コメント参照）─────────────────
    SELECT string_agg(x, ', ') INTO v_svc FROM (
        SELECT 'table'    AS x WHERE has_table_privilege('service_role', 'public.zz_029_verify_tbl', 'SELECT')
        UNION ALL
        SELECT 'sequence'      WHERE has_sequence_privilege('service_role', 'public.zz_029_verify_seq', 'SELECT')
        UNION ALL
        SELECT 'function'      WHERE has_function_privilege('service_role', 'public.zz_029_verify_fn()', 'EXECUTE')
    ) s;

    -- ── 後始末 ──────────────────────────────────────────────────────────
    DROP FUNCTION public.zz_029_verify_fn();
    DROP SEQUENCE public.zz_029_verify_seq;
    DROP TABLE public.zz_029_verify_tbl;

    RAISE NOTICE '029 object-creation verify passed: newly created table/sequence/function grant nothing to PUBLIC/anon/authenticated';
    RAISE NOTICE '029 object-creation info: service_role was auto-granted on -> % (expected until the default-privilege correction is approved and applied)',
        coalesce(v_svc, '(none)');
END $$;
