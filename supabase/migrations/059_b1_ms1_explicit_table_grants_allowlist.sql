-- ============================================================================
-- 059_b1_ms1_explicit_table_grants_allowlist.sql
--
-- 田島様2026-08-06ご指摘3への対応。
-- 「本番のGRANT状態を明示的なmigrationとして追加し、権限まで含めて再現可能な
--   配置手順とすること。ただし本番の現在値を機械的にコピーするのではなく、
--   REVOKEを基準にanon・authenticatedへ必要な権限だけを明示する許可リスト方式」
--
-- 【背景】
--   これまで `anon`・`authenticated` へのテーブル権限は、いずれのmigrationにも
--   明示されていなかった。Supabaseがプロジェクト作成時に設定する既定権限に
--   依存していたため、`DROP SCHEMA public CASCADE` を経たゼロからの通し適用では
--   権限が復元されず、migration一式だけでは本番と同一の状態を再現できなかった。
--
-- 【方式】
--   (1) まず `anon`・`authenticated` から public スキーマの全テーブル権限を剥奪する
--   (2) そのうえで、必要な権限だけを表ごとに明示的に付与する
--   これにより、本migration適用後の権限状態は「ここに書かれているものが全て」に
--   なり、以後は新規テーブルを追加しても明示的に付与しない限り権限は付かない。
--   （新規オブジェクトへの既定権限は migration 022・029 で剥奪済み）
--
-- 【付与対象の決め方】
--   本番の現在値をそのまま写すのではなく、次の2条件をともに満たすものだけを
--   許可リストに載せた。
--     A. アプリケーションが実際にその操作を行っている（`src/` 配下の実使用）
--     B. その操作を許可するRLSポリシーが存在し、当該ロールを対象にしている
--   Bを満たさない権限は、付与されていても実際にはRLSで拒否されるため、
--   「効かない権限が付いている」状態を解消する意味でも剥奪する。
--
-- 【適用前の状態】
--   適用前の本番ACL全量（51行）は
--   `supabase/verification/acl_snapshot_before_059.txt` に記録として保全した。
--
-- 【本migrationで剥奪される主なもの（適用前は付与されていた）】
--   ・anon の全テーブル権限（下記マスタ5表のSELECTを除く）
--     いずれも `anon` を対象とするRLSポリシーが存在せず、権限が付いていても
--     行は1件も返らない状態だった（＝実質的に無効な権限）。
--   ・authenticated の agency_config への INSERT・UPDATE
--     SELECTポリシーのみ存在し、書込みポリシーが無いため実質無効だった。
--     アプリも参照のみ。
--   ・authenticated の agency_rule_override への INSERT・UPDATE
--     同上（SELECTポリシーのみ）。
--   ・authenticated の operator への INSERT
--     INSERTポリシーが存在せず、アプリも参照のみ。
--
-- 【検証】
--   ・本番適用後に `supabase/verification/050_058_check.sql` と
--     `runtime_http_checks.sh` を再実行し、既存フローに影響がないことを確認する
--   ・新規DBへの001からの通し適用でも同一の権限状態になることを確認する
-- ============================================================================

-- ── (1) 基準となる剥奪 ──────────────────────────────────────────────────
-- public スキーマの現存する全テーブルから、両ロールの権限を一旦すべて外す。
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM authenticated;

-- スキーマ自体のUSAGEは必要（これが無いとテーブルへ到達できない）。
-- Supabaseの新規プロジェクトでは既定で付与されるが、ゼロからの再適用でも
-- 同じ状態になるよう明示する。
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;

-- ── (2) authenticated への明示的な付与 ─────────────────────────────────

-- run: 案件の作成・参照・更新。RLSは自代理店スコープ（001・014）。
--      確定専有列・同意系列の直接更新はトリガーで拒否される（050・056）。
GRANT SELECT, INSERT, UPDATE ON public.run TO authenticated;

-- operator: 自分自身の解決に参照する（auth_user_id → operator）。
--           INSERTポリシーは存在せず、アプリも作成しないため参照のみ。
GRANT SELECT ON public.operator TO authenticated;

-- audit_event: 監査ログの記録と参照。UPDATE/DELETEはポリシー不在で拒否
--              （ポリシーを作らないことで拒否する設計。011・039）。
GRANT SELECT, INSERT ON public.audit_event TO authenticated;

-- snapshot: 案件作成時に1件作成し、以後参照する。
--           重複補償判断・解消メモの更新は専用RPC経由（032・044）。
GRANT SELECT, INSERT ON public.snapshot TO authenticated;

-- candidate: 参照のみ。追加・除外・補償状況変更はすべてRPC経由
--            （051で直接INSERT権限を剥奪済み）。
GRANT SELECT ON public.candidate TO authenticated;

-- agency_config: 代理店名等の参照のみ。
GRANT SELECT ON public.agency_config TO authenticated;

-- agency_rule_override: SELECTポリシーのみ存在するため参照のみ。
GRANT SELECT ON public.agency_rule_override TO authenticated;

-- property_profile: 参照のみ。保存は save_property_profile() RPC経由（015・037）。
GRANT SELECT ON public.property_profile TO authenticated;

-- intent_confirmation / csv_import_session:
--   いずれも `ALL` のRLSポリシーが存在し、書込みを想定した設計。
--   親runが draft / post_record_pending 以外の場合は、共通トリガー
--   `enforce_parent_run_not_finalized` が書込みを拒否する（046・055・056）。
GRANT SELECT, INSERT, UPDATE ON public.intent_confirmation TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.csv_import_session TO authenticated;

-- 参照系マスタ5表: `USING (true)` の公開読取りポリシーを持つ。
GRANT SELECT ON public.coverage_rule_master      TO authenticated;
GRANT SELECT ON public.flood_zone_master         TO authenticated;
GRANT SELECT ON public.insurance_category        TO authenticated;
GRANT SELECT ON public.insurance_line            TO authenticated;
GRANT SELECT ON public.restriction_reason_master TO authenticated;

-- ── (3) anon への明示的な付与 ──────────────────────────────────────────
-- `anon` を対象に含むRLSポリシーは、下記マスタ5表の公開読取り
-- （`TO public USING (true)`）のみである。他のテーブルは `anon` を対象とする
-- ポリシーが存在せず、権限を付与しても行は返らないため付与しない。
GRANT SELECT ON public.coverage_rule_master      TO anon;
GRANT SELECT ON public.flood_zone_master         TO anon;
GRANT SELECT ON public.insurance_category        TO anon;
GRANT SELECT ON public.insurance_line            TO anon;
GRANT SELECT ON public.restriction_reason_master TO anon;

-- ── (4) 明示的に付与しないテーブル（記録として列挙） ────────────────────
--   run_proof              : 証跡本文。SECURITY DEFINER関数からのみ操作（056）
--   run_participant        : deny-all。田島様2026-08-04ご決定（053）
--   smartphone_confirm_token: deny-all。トークン操作は専用RPC経由（016・041）
--   上記3表には anon・authenticated への権限を一切付与しない。

-- ── (5) 適用結果の自己検査 ─────────────────────────────────────────────
DO $$
DECLARE
    v_unexpected text;
    v_missing    text;
BEGIN
    -- 許可リストに無い権限が残っていないこと
    SELECT string_agg(format('%s/%s/%s', table_name, grantee, privilege_type), ', ')
      INTO v_unexpected
      FROM information_schema.role_table_grants g
     WHERE g.table_schema = 'public'
       AND g.grantee IN ('anon', 'authenticated')
       AND NOT (
            (g.grantee = 'authenticated' AND g.table_name = 'run'                  AND g.privilege_type IN ('SELECT','INSERT','UPDATE')) OR
            (g.grantee = 'authenticated' AND g.table_name = 'operator'             AND g.privilege_type = 'SELECT') OR
            (g.grantee = 'authenticated' AND g.table_name = 'audit_event'          AND g.privilege_type IN ('SELECT','INSERT')) OR
            (g.grantee = 'authenticated' AND g.table_name = 'snapshot'             AND g.privilege_type IN ('SELECT','INSERT')) OR
            (g.grantee = 'authenticated' AND g.table_name = 'candidate'            AND g.privilege_type = 'SELECT') OR
            (g.grantee = 'authenticated' AND g.table_name = 'agency_config'        AND g.privilege_type = 'SELECT') OR
            (g.grantee = 'authenticated' AND g.table_name = 'agency_rule_override' AND g.privilege_type = 'SELECT') OR
            (g.grantee = 'authenticated' AND g.table_name = 'property_profile'     AND g.privilege_type = 'SELECT') OR
            (g.grantee = 'authenticated' AND g.table_name IN ('intent_confirmation','csv_import_session')
                                                                                   AND g.privilege_type IN ('SELECT','INSERT','UPDATE')) OR
            (g.table_name IN ('coverage_rule_master','flood_zone_master','insurance_category',
                              'insurance_line','restriction_reason_master')        AND g.privilege_type = 'SELECT')
       );
    IF v_unexpected IS NOT NULL THEN
        RAISE EXCEPTION '059 failed: unexpected grants remain -> %', v_unexpected;
    END IF;

    -- アプリが依存する権限が確実に付いていること
    SELECT string_agg(x, ', ') INTO v_missing FROM (
        SELECT 'run/SELECT' x WHERE NOT has_table_privilege('authenticated','public.run','SELECT')
        UNION ALL SELECT 'run/INSERT'   WHERE NOT has_table_privilege('authenticated','public.run','INSERT')
        UNION ALL SELECT 'run/UPDATE'   WHERE NOT has_table_privilege('authenticated','public.run','UPDATE')
        UNION ALL SELECT 'operator/SELECT'    WHERE NOT has_table_privilege('authenticated','public.operator','SELECT')
        UNION ALL SELECT 'audit_event/INSERT' WHERE NOT has_table_privilege('authenticated','public.audit_event','INSERT')
        UNION ALL SELECT 'snapshot/INSERT'    WHERE NOT has_table_privilege('authenticated','public.snapshot','INSERT')
        UNION ALL SELECT 'candidate/SELECT'   WHERE NOT has_table_privilege('authenticated','public.candidate','SELECT')
        UNION ALL SELECT 'flood_zone_master/SELECT' WHERE NOT has_table_privilege('authenticated','public.flood_zone_master','SELECT')
        UNION ALL SELECT 'property_profile/SELECT'  WHERE NOT has_table_privilege('authenticated','public.property_profile','SELECT')
    ) s;
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION '059 failed: required grants missing -> %', v_missing;
    END IF;

    -- deny-all を維持すべき3表に権限が付いていないこと
    IF EXISTS (SELECT 1 FROM information_schema.role_table_grants
                WHERE table_schema='public' AND grantee IN ('anon','authenticated')
                  AND table_name IN ('run_proof','run_participant','smartphone_confirm_token')) THEN
        RAISE EXCEPTION '059 failed: deny-all tables must not be granted';
    END IF;

    RAISE NOTICE '059: explicit grant allow-list applied and verified';
END;
$$;
