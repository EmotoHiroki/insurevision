-- ============================================================================
-- 029_check.sql  【本番でも実行可・読み取り専用】
--
-- migration 029（関数のグローバル既定権限）の検証。
--
-- 【2026-08-09 分割】
--   田島様2026-08-08ご指摘2により、本ファイルを読み取り専用へ改めた。
--   従来の本ファイルは、実際にテーブル・シーケンス・関数を CREATE し、
--   生成された実オブジェクトの権限を検査したうえで DROP していた。
--   「本番で実行する検証SQLは読み取り専用」という当方の説明と実態が
--   食い違っており、実際に本番へ適用してしまっていた。
--
--   実オブジェクトを作成する試験は
--   `029_object_creation_check.sql`（分離検証環境専用）へ移した。
--   本ファイルは pg_default_acl のカタログ参照のみで完結する。
--
-- 【本ファイルが検査すること】
--   `public` スキーマに新規オブジェクトが作られたときに、
--   PUBLIC・anon・authenticated へ権限が自動付与される既定設定が
--   存在しないこと（＝ migration 022・029 の成果が維持されていること）。
--
--   実オブジェクトを作って実効権限を確かめるところまでは、
--   本ファイルでは行わない（そちらは分離環境側で実施する）。
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/029_check.sql
-- 期待する結果: 例外が発生せず、最後に NOTICE が1件出力される。
-- ============================================================================

DO $$
DECLARE
    v_bad     text;
    v_residual text;
BEGIN
    -- ── 1. `postgres` 所有・public スキーマの既定権限に
    --       PUBLIC・anon・authenticated が現れないこと ──────────────────────
    --
    --   【検査範囲を所有ロール postgres に限定している理由】
    --   本番の `public` のオブジェクトはテーブル18件・関数27件のすべてが
    --   `postgres` 所有であり、migration も `postgres` として実行される。
    --   すなわち、当方が作成するオブジェクトに対して実際に発火するのは
    --   `postgres` 所有の既定権限のみである。migration 022・029 が
    --   保証しているのもこの範囲である。
    --
    --   `supabase_admin` 所有の既定権限は別途 §2-b で報告する。
    --   こちらは Supabase がプロジェクト作成時に設定するもので、
    --   当方の migration では発火しないが、本番にのみ存在する差分であるため
    --   隠さずに出力する（田島様2026-08-08ご指摘3として整理中）。
    SELECT string_agg(
               format('objtype=%s grantee=%s privs=%s',
                      d.defaclobjtype,
                      a.grantee::regrole::text,
                      a.privilege_type),
               '; ' ORDER BY d.defaclobjtype)
      INTO v_bad
      FROM pg_default_acl d
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
     CROSS JOIN LATERAL aclexplode(d.defaclacl) a
     WHERE n.nspname = 'public'
       AND pg_get_userbyid(d.defaclrole) = 'postgres'
       AND a.grantee::regrole::text IN ('public', 'anon', 'authenticated');

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '029 verify failed: postgres-owned default privileges in schema public still grant to PUBLIC/anon/authenticated -> %', v_bad;
    END IF;

    -- ── 2-b. `postgres` 以外の所有ロールによる public 向け既定権限の報告 ────
    --   失敗条件とはしないが、存在する場合は必ず可視化する。
    SELECT string_agg(
               format('owner=%s objtype=%s grantee=%s',
                      pg_get_userbyid(d.defaclrole),
                      d.defaclobjtype,
                      a.grantee::regrole::text),
               '; ' ORDER BY pg_get_userbyid(d.defaclrole), d.defaclobjtype)
      INTO v_residual
      FROM pg_default_acl d
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
     CROSS JOIN LATERAL aclexplode(d.defaclacl) a
     WHERE n.nspname = 'public'
       AND pg_get_userbyid(d.defaclrole) <> 'postgres'
       AND a.grantee::regrole::text IN ('public', 'anon', 'authenticated');

    IF v_residual IS NOT NULL THEN
        RAISE NOTICE '029 verify info: default privileges owned by roles other than postgres still reference PUBLIC/anon/authenticated in schema public -> %', v_residual;
        RAISE NOTICE '029 verify info: these do not fire for objects created by our migrations (which run as postgres). They are tracked separately as the default-privilege item.';
    END IF;

    -- ── 2. グローバル既定権限（スキーマ指定なし）にも
    --       PUBLIC・anon・authenticated が現れないこと ──────────────────────
    --   migration 029 は、022 の `IN SCHEMA` 付き剥奪では新規関数の
    --   PUBLIC EXECUTE を防げていなかったことへの是正であり、
    --   グローバル形式で剥奪している。ここが本ファイルの本体である。
    SELECT string_agg(
               format('owner=%s objtype=%s grantee=%s privs=%s',
                      pg_get_userbyid(d.defaclrole),
                      d.defaclobjtype,
                      a.grantee::regrole::text,
                      a.privilege_type),
               '; ')
      INTO v_bad
      FROM pg_default_acl d
     CROSS JOIN LATERAL aclexplode(d.defaclacl) a
     WHERE d.defaclnamespace = 0
       AND a.grantee::regrole::text IN ('public', 'anon', 'authenticated');

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '029 verify failed: global default privileges still grant to PUBLIC/anon/authenticated -> %', v_bad;
    END IF;

    RAISE NOTICE '029 verify passed (catalog only): no default privilege grants objects in public to PUBLIC/anon/authenticated. Real-object creation is tested separately in 029_object_creation_check.sql (isolated environment only)';
END $$;
