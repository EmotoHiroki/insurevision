-- ============================================================================
-- schema_fingerprint.sql
--
-- 2つのDB（本番と、新規DBへ001から通し適用した検証用DB）の状態が一致することを、
-- オブジェクト名だけでなく「定義そのもの」で比較するための指紋を出力する。
--
-- 田島様2026-08-06ご指摘8への対応:
--   「オブジェクト名62件の連結SHA-256一致が示すのは名称の一致までで、関数本文、
--     RLSポリシー式、トリガー定義、列制約、GRANTの一致までは示さない」
--
-- 出力: 1行1オブジェクトの正規化テキスト（category, object_key, definition）。
--   両DBで本スクリプトを実行し、結果を突き合わせて差分0件であることを確認する。
--   合計のSHA-256（最終行 __TOTAL__）が一致すれば、下記すべてが一致している。
--     - テーブルと列（型・NOT NULL・既定値）
--     - 制約（PRIMARY KEY / UNIQUE / CHECK / FOREIGN KEY）
--     - 関数（本文・引数・戻り値・SECURITY DEFINER・search_path設定）
--     - RLSの有効/強制状態
--     - RLSポリシー（対象ロール・USING式・WITH CHECK式）
--     - トリガー（定義全文。storage.objects上のものを含む）
--     - anon / authenticated へのテーブル権限
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/schema_fingerprint.sql
-- 読み取りのみで、データを一切変更しない。
-- ============================================================================

WITH
columns_def AS (
    SELECT 'column' AS category,
           c.table_name || '.' || c.column_name AS object_key,
           c.data_type || '|' || c.is_nullable || '|' ||
               coalesce(c.column_default, '(none)') AS definition
      FROM information_schema.columns c
     WHERE c.table_schema = 'public'
),
constraints_def AS (
    SELECT 'constraint' AS category,
           c.conrelid::regclass::text || '.' || c.conname AS object_key,
           pg_get_constraintdef(c.oid) AS definition
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE n.nspname = 'public'
),
functions_def AS (
    SELECT 'function' AS category,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS object_key,
           md5(pg_get_functiondef(p.oid)) || '|secdef=' || p.prosecdef::text
               || '|cfg=' || coalesce(array_to_string(p.proconfig, ','), '(none)') AS definition
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
),
rls_state AS (
    SELECT 'rls' AS category,
           c.relname AS object_key,
           'enabled=' || c.relrowsecurity::text || '|forced=' || c.relforcerowsecurity::text AS definition
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r'
),
policies_def AS (
    SELECT 'policy' AS category,
           p.schemaname || '.' || p.tablename || '.' || p.policyname AS object_key,
           p.cmd || '|roles=' || p.roles::text
               || '|using=' || coalesce(p.qual, '(none)')
               || '|check=' || coalesce(p.with_check, '(none)') AS definition
      FROM pg_policies p
     WHERE p.schemaname IN ('public', 'storage')
),
triggers_def AS (
    SELECT 'trigger' AS category,
           n.nspname || '.' || c.relname || '.' || t.tgname AS object_key,
           pg_get_triggerdef(t.oid) AS definition
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE NOT t.tgisinternal AND n.nspname IN ('public', 'storage')
),
grants_def AS (
    SELECT 'grant' AS category,
           g.table_name || '.' || g.grantee || '.' || g.privilege_type AS object_key,
           'granted' AS definition
      FROM information_schema.role_table_grants g
     WHERE g.table_schema = 'public'
       AND g.grantee IN ('anon', 'authenticated')
),
all_rows AS (
    SELECT * FROM columns_def
    UNION ALL SELECT * FROM constraints_def
    UNION ALL SELECT * FROM functions_def
    UNION ALL SELECT * FROM rls_state
    UNION ALL SELECT * FROM policies_def
    UNION ALL SELECT * FROM triggers_def
    UNION ALL SELECT * FROM grants_def
)
SELECT category, object_key, definition
  FROM all_rows
UNION ALL
SELECT '__TOTAL__',
       count(*)::text,
       md5(string_agg(category || '|' || object_key || '|' || definition,
                      E'\n' ORDER BY category, object_key, definition))
  FROM all_rows
 ORDER BY 1, 2, 3;
