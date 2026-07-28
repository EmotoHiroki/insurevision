-- ============================================================================
-- 019_b1_ms1_revoke_rls_exempt_privileges.sql
--
-- 状態: 本番適用済み（本ファイル作成と同一セッションで適用・実測）
--
-- 目的: TRUNCATE・REFERENCES・MAINTAIN は行単位のRLSポリシーによる制御の
--       対象外であるため、不要な付与を anon・authenticated から剥奪する
--       （田島様2026-07-27 23:41ご指摘2）。
--
-- 適用前の実測（has_table_privilege による raw scan。17テーブル×3ロール）:
--   TRUNCATE・REFERENCESが true: agency_config, agency_rule_override,
--     candidate, coverage_rule_master, csv_import_session, flood_zone_master,
--     insurance_category, insurance_line, intent_confirmation,
--     restriction_reason_master, run_participant, snapshot （12テーブル、
--     anon・authenticated 双方で同一）
--   TRUNCATE・REFERENCESが既に false: audit_event, operator, property_profile,
--     run, smartphone_confirm_token （5テーブル。013でTRUNCATE/REFERENCES/
--     TRIGGERをrun/operator/audit_event/property_profileから剥奪済み、016で
--     smartphone_confirm_tokenを全剥奪済みのため）
--   MAINTAINが true: smartphone_confirm_token以外の全16テーブルで
--     anon・authenticated 双方
--
--   ご指摘の「authenticatedはproperty_profile・runを含む14件でTRUNCATEを持つ」
--   という認識は、実測では成立しません。property_profile・runは013の適用時点で
--   TRUNCATE・REFERENCESともに剥奪済みです。実際にTRUNCATEを保持しているのは
--   12テーブルで、anon・authenticatedの差はありません。
--
-- MAINTAINについて: データ削除権限ではないが、VACUUM・CLUSTER・REINDEX・
--   LOCK TABLEを許可するため、本番稼働への影響という別軸のリスクがある。
--   ご指摘のとおりTRUNCATEとは分けて扱うが、剥奪自体は同時に行う。
--
-- 対象外の判断: 参照マスタ（coverage_rule_master・flood_zone_master・
--   insurance_category・insurance_line・restriction_reason_master）も含め
--   全テーブルを対象とする。読取り専用マスタであっても、TRUNCATE・MAINTAIN
--   は業務データではなく本番稼働そのものに影響するため、公開読取りの方針とは
--   独立して剥奪する。
-- ============================================================================

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'agency_config','agency_rule_override','candidate','coverage_rule_master',
        'csv_import_session','flood_zone_master','insurance_category','insurance_line',
        'intent_confirmation','restriction_reason_master','run_participant','snapshot'
    ] LOOP
        EXECUTE format('REVOKE TRUNCATE, REFERENCES ON TABLE public.%I FROM anon, authenticated', t);
    END LOOP;

    -- MAINTAIN: 16テーブル全件（smartphone_confirm_tokenは016で既に全剥奪済み）
    FOREACH t IN ARRAY ARRAY[
        'agency_config','agency_rule_override','audit_event','candidate','coverage_rule_master',
        'csv_import_session','flood_zone_master','insurance_category','insurance_line',
        'intent_confirmation','operator','property_profile','restriction_reason_master',
        'run','run_participant','snapshot'
    ] LOOP
        EXECUTE format('REVOKE MAINTAIN ON TABLE public.%I FROM anon, authenticated', t);
    END LOOP;
END;
$$;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_remaining text;
BEGIN
    SELECT string_agg(format('%s/%s/%s', c.relname, r.rolname, p.priv), ', ')
      INTO v_remaining
      FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
     CROSS JOIN (VALUES ('anon'),('authenticated')) AS r(rolname)
     CROSS JOIN (VALUES ('TRUNCATE'),('REFERENCES'),('MAINTAIN')) AS p(priv)
     WHERE n.nspname='public' AND c.relkind='r' AND c.relname <> 'smartphone_confirm_token'
       AND has_table_privilege(r.rolname, c.oid, p.priv);

    IF v_remaining IS NOT NULL THEN
        RAISE EXCEPTION '019 self-check failed: RLS-exempt privileges remain -> %', v_remaining;
    END IF;

    RAISE NOTICE '019 self-check passed: no TRUNCATE/REFERENCES/MAINTAIN remain for anon/authenticated on any of the 16 non-token tables';
END;
$$;
