-- ============================================================================
-- 022_b1_ms1_default_privileges_public_schema.sql
--
-- 状態: 本番適用済み（本ファイル作成と同一セッションで適用・実測）
--
-- 背景（田島様2026-07-27 23:41ご指摘8への対応）:
--
--   finalize_run に PUBLIC の EXECUTE が付与されていた根本原因を
--   pg_default_acl で特定した。
--
--   `public` スキーマにおいて、オブジェクト作成ロール `postgres`（本プロジェクトの
--   migrationはすべてこのロールで実行される）の既定権限は次のとおりだった：
--     - 新規テーブル: anon・authenticated に arwdDxtm（ほぼ全権限）を自動付与
--     - 新規シーケンス: anon・authenticated に rwU を自動付与
--     - 新規関数: anon・authenticated に X（EXECUTE）を自動付与
--
--   すなわち、`postgres` ロールで `CREATE TABLE` や `CREATE FUNCTION` を実行すると、
--   個別のGRANT文を書かなくても anon・authenticated が自動的にフルアクセスを
--   持つ状態だった。finalize_run・get_my_agency_id への PUBLIC EXECUTE 付与は、
--   この既定設定がそのまま顕在化したものであり、個別のミスではない。
--
--   なお `supabase_admin`（Supabaseプラットフォーム自体が使用する内部ロール）にも
--   同様の既定権限が設定されているが、これはSupabase自体の管理下にある規約であり、
--   本プロジェクトのmigrationが使用するロールではないため、本migrationでは
--   変更しない。
--
-- 対応: `postgres` ロールが `public` スキーマに作成する新規オブジェクトについて、
--   anon・authenticated への既定権限をすべて剥奪する。今後のテーブル・関数・
--   シーケンス作成時は、必要な権限を個別のGRANT文で明示的に付与する運用とする
--   （第4段階の3関数で既に採用している方式：CREATE直後にREVOKE FROM PUBLIC,
--   anonしGRANTで許可ロールのみ明示、と同じ考え方をテーブル・シーケンスにも
--   拡張するもの）。
--
-- 重要な注意点（既存オブジェクトへの非遡及性）:
--   ALTER DEFAULT PRIVILEGES は「今後作成されるオブジェクト」にのみ適用され、
--   既存の17テーブル・8関数の権限には一切影響しない。既存分の是正は
--   016〜021の各migrationで個別に実施済み。
--
--   今後、本プロジェクトで新規テーブル・関数を作成する際（第5段階の
--   save_property_profile関連、MS2のcoverage_rule_master関連等）は、
--   既定では anon・authenticated に一切の権限がない状態から始まる。
--   必要な権限は各migrationファイル内で明示的にGRANTすること。
-- ============================================================================

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM anon, authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON FUNCTIONS FROM PUBLIC;

-- ── 自己検査 ────────────────────────────────────────────────────────────
-- 注: 実運用時、本自己検査ブロックが例外を送出すると、同一バッチ内の
--     直前のALTER DEFAULT PRIVILEGES文もまとめてロールバックされることを
--     実測で確認した（execute_sql は複数文を暗黙の単一トランザクションで
--     実行するため）。したがって自己検査は誤検知を起こさない厳密な
--     パターンで判定する。
DO $$
DECLARE
    v_table_acl text;
    v_seq_acl text;
    v_func_acl text;
BEGIN
    SELECT defaclacl::text INTO v_table_acl FROM pg_default_acl
     WHERE defaclrole = 'postgres'::regrole AND defaclnamespace = 'public'::regnamespace AND defaclobjtype = 'r';
    SELECT defaclacl::text INTO v_seq_acl FROM pg_default_acl
     WHERE defaclrole = 'postgres'::regrole AND defaclnamespace = 'public'::regnamespace AND defaclobjtype = 'S';
    SELECT defaclacl::text INTO v_func_acl FROM pg_default_acl
     WHERE defaclrole = 'postgres'::regrole AND defaclnamespace = 'public'::regnamespace AND defaclobjtype = 'f';

    IF v_table_acl LIKE '%,anon=%' OR v_table_acl LIKE '{anon=%' OR v_table_acl LIKE '%,authenticated=%' OR v_table_acl LIKE '{authenticated=%' THEN
        RAISE EXCEPTION '022 self-check failed: table default ACL still grants anon/authenticated -> %', v_table_acl;
    END IF;
    IF v_func_acl LIKE '%,anon=%' OR v_func_acl LIKE '{anon=%' OR v_func_acl LIKE '%,authenticated=%' OR v_func_acl LIKE '{authenticated=%' THEN
        RAISE EXCEPTION '022 self-check failed: function default ACL still grants anon/authenticated -> %', v_func_acl;
    END IF;

    RAISE NOTICE '022 self-check passed. table_acl=%  seq_acl=%  func_acl=%', v_table_acl, v_seq_acl, v_func_acl;
END;
$$;
