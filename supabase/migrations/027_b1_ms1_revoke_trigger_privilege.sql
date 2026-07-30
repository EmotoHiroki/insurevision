-- ============================================================================
-- 027_b1_ms1_revoke_trigger_privilege.sql
--
-- 状態: 本番適用済み
--
-- 背景（026の横展開スイープ中に自ら発見。田島様からの直接のご指摘ではない）:
--   026（B-1: DELETE剥奪）の適用後、田島様2026-07-30ご指摘C-12「同型箇所への
--   横展開」に従い、他のRLS対象外権限が残っていないか無条件に走査した。
--
--   TRIGGER権限（`CREATE TRIGGER ON テーブル` を許可する。TRUNCATE・
--   REFERENCES・MAINTAINと同様、行単位のRLSポリシーの対象外）が、
--   12テーブルで anon・authenticated 双方に残存していることが判明した。
--
--     restriction_reason_master, agency_rule_override, agency_config,
--     snapshot, run_participant, csv_import_session, candidate,
--     insurance_category, insurance_line, coverage_rule_master,
--     flood_zone_master, intent_confirmation
--
--   019（TRUNCATE・REFERENCES・MAINTAINの剥奪）は、このTRIGGER権限を対象に
--   含めていなかった。RLSの対象外である権限を一括で洗い出す際に、
--   pg_class.relacl の全権限文字（arwdDxtm）のうち t（TRIGGER）を見落として
--   いたことが原因。
--
--   アプリコード（src/）を無条件走査した結果、`CREATE TRIGGER` に相当する
--   操作は0件（Supabaseクライアントライブラリ経由のDDL実行はそもそも
--   想定されていない）。RLSポリシーによる制御も対象外のため、019と同じ
--   理由で剥奪する。
--
-- 対応:
--   全17テーブルについて、anon・authenticated から TRIGGER を剥奪する。
-- ============================================================================

DO $$
DECLARE
    v_table text;
BEGIN
    FOR v_table IN
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r'
    LOOP
        EXECUTE format('REVOKE TRIGGER ON TABLE public.%I FROM anon, authenticated', v_table);
    END LOOP;
END;
$$;
