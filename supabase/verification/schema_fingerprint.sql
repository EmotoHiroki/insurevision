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
--     - 関数のEXECUTE権限（proacl。2026-08-06追加）
--     - インデックス定義（2026-08-06追加）
--     - storageバケットの定義（2026-08-06追加）
--     - 既定権限（pg_default_acl。2026-08-06追加）
--
-- 【2026-08-06の重要な修正】
--   初版はテーブル権限のみを対象としており、関数のEXECUTE権限・インデックス・
--   バケット・既定権限を見ていなかった。そのため「本番と通し適用後が完全一致」と
--   判定していても、実際にはこれら4種に差分が存在しうる状態だった。
--   実際に本番と通し適用後を比較したところ、初版の対象範囲では差分0件であったのに対し、
--   上記4種を追加したところ差分が検出された。検証範囲より強い主張をしていたことになる。
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
function_grants_def AS (
    -- 関数のEXECUTE権限（anon・authenticated）。057・058・059が
    -- REVOKE/GRANT ON FUNCTION を多用するため、ここを見ていないと
    -- 「内部専用関数がauthenticatedへ再付与された」といった退行を検出できない。
    --
    -- 【2026-08-09】田島様ご指摘6により、service_role 分を別分類へ分離した。
    -- 従来は3ロールを1分類（function_grant）としてまとめて出力していたため、
    -- 「anon・authenticated向け54件」が総件数のどこに位置づくかを
    -- 出力から機械的に示せなかった。
    -- 本分類は 関数27件 × 2ロール = 54行 を出力する（付与の有無を true/false で保持）。
    SELECT 'function_grant_anon_auth' AS category,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' || '.' || r.rolname AS object_key,
           has_function_privilege(r.rolname, p.oid, 'EXECUTE')::text AS definition
      FROM pg_proc p
      CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r.rolname)
),
service_function_grants_def AS (
    -- 関数のEXECUTE権限（service_role）。066・067で許可リスト化した対象。
    -- 関数27件 × 1ロール = 27行を出力する。
    SELECT 'function_grant_service' AS category,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' || '.service_role' AS object_key,
           has_function_privilege('service_role', p.oid, 'EXECUTE')::text AS definition
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role')
),
indexes_def AS (
    SELECT 'index' AS category,
           schemaname || '.' || indexname AS object_key,
           indexdef AS definition
      FROM pg_indexes
     WHERE schemaname = 'public'
),
buckets_def AS (
    SELECT 'bucket' AS category,
           id AS object_key,
           'public=' || coalesce(public::text, '(null)') AS definition
      FROM storage.buckets
),
default_acl_def AS (
    SELECT 'default_acl' AS category,
           coalesce(n.nspname, '(global)') || '.' || d.defaclobjtype::text AS object_key,
           coalesce(d.defaclacl::text, '(null)') AS definition
      FROM pg_default_acl d
      LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
),
schema_priv_def AS (
    -- スキーマ利用権限。2026-08-06追加。
    -- これを見ていなかったため、migration 059が `GRANT USAGE ON SCHEMA public` を
    -- service_role へ付与していない点を検出できなかった。本番はプロジェクト作成時の
    -- 初期設定で保持しているため差分が表面化せず、ゼロからの通し適用後のDBでのみ
    -- サーバー側処理が動かない状態になっていた（migration 064で是正）。
    SELECT 'schema_priv' AS category,
           n.nspname || '.' || r.rolname || '.' || p.priv AS object_key,
           has_schema_privilege(r.rolname, n.nspname, p.priv)::text AS definition
      FROM pg_namespace n
      CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rolname)
      CROSS JOIN (VALUES ('USAGE'), ('CREATE')) AS p(priv)
     WHERE n.nspname IN ('public', 'storage')
       AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r.rolname)
),
service_role_table_grants AS (
    -- service_role のテーブル権限。2026-08-06追加。
    -- 従来のgrants_defは anon・authenticated のみを対象としており、
    -- サーバー側処理が用いる service_role の到達範囲を比較していなかった。
    SELECT 'service_grant' AS category,
           g.table_name || '.' || g.privilege_type AS object_key,
           'granted' AS definition
      FROM information_schema.role_table_grants g
     WHERE g.table_schema = 'public'
       AND g.grantee = 'service_role'
),
all_rows AS (
    SELECT * FROM columns_def
    UNION ALL SELECT * FROM constraints_def
    UNION ALL SELECT * FROM functions_def
    UNION ALL SELECT * FROM rls_state
    UNION ALL SELECT * FROM policies_def
    UNION ALL SELECT * FROM triggers_def
    UNION ALL SELECT * FROM grants_def
    UNION ALL SELECT * FROM function_grants_def
    UNION ALL SELECT * FROM service_function_grants_def
    UNION ALL SELECT * FROM indexes_def
    UNION ALL SELECT * FROM buckets_def
    UNION ALL SELECT * FROM default_acl_def
    UNION ALL SELECT * FROM schema_priv_def
    UNION ALL SELECT * FROM service_role_table_grants
),
-- ── 比較対象とするか否かを、SQL自身が保持する ────────────────────────────
--   田島様2026-08-08ご指摘6により、「どの分類を比較し、どれを意図的に
--   除外しているか」と「その件数」を、資料側の主張ではなく
--   SQLの実出力から機械的に導ける形にする。
--
--   excluded の2分類を除外する理由:
--     default_acl … Supabaseがプロジェクト作成時に設定する既定権限。
--                   どのmigrationにも記録が無く、再現すると以後 public に
--                   作成する全オブジェクトが自動開放される構成になるため、
--                   意図的に再現しない（別途ご相談中の事項）。
--     bucket      … 本番にのみ存在する run-pdfs（オブジェクト0件・参照0件）。
--                   削除は本番の実体を消す操作にあたるためmigrationで扱わない。
scoped AS (
    SELECT category, object_key, definition,
           CASE WHEN category IN ('default_acl', 'bucket') THEN 'excluded'
                ELSE 'compared' END AS scope
      FROM all_rows
)
SELECT category, object_key, definition
  FROM scoped
 WHERE scope = 'compared'

UNION ALL
-- 分類ごとの件数（実出力から算出）
SELECT '__COUNT__' || scope || '.' || category,
       count(*)::text,
       ''
  FROM scoped
 GROUP BY scope, category

UNION ALL
-- 比較対象の合計件数と指紋
SELECT '__COMPARED_TOTAL__',
       count(*)::text,
       md5(string_agg(category || '|' || object_key || '|' || definition,
                      E'\n' ORDER BY category, object_key, definition))
  FROM scoped
 WHERE scope = 'compared'

UNION ALL
-- 意図的に除外した分の合計件数（比較には用いないが、隠さず出力する）
SELECT '__EXCLUDED_TOTAL__',
       count(*)::text,
       ''
  FROM scoped
 WHERE scope = 'excluded'

 ORDER BY 1, 2, 3;
