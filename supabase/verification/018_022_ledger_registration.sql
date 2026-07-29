-- ============================================================================
-- 018_022_ledger_registration.sql
--
-- 重要: これは migration ではない。018〜022 は execute_sql 経由で本番へ
-- 直接適用済みであり、DDLの再実行は行わない。本ファイルは、016・017と
-- 同じ理由（execute_sql経由の適用は台帳へ自動記録されない）で欠落していた
-- 台帳エントリを、2026-07-29に事後登録した記録である。
--
-- 田島様2026-07-29ご指摘1（018の台帳記録の欠落）を受けて確認したところ、
-- 018だけでなく019〜022も同様に台帳未登録であることが判明したため、
-- 5件まとめて登録した。
-- ============================================================================

INSERT INTO supabase_migrations.schema_migrations (version, name, statements) VALUES
('20260728000001', '018_b1_ms1_agency_scope_snapshot_candidate_and_active_operator', ARRAY[
  $q$CREATE OR REPLACE FUNCTION public.get_my_agency_id() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$ SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() AND is_active = true LIMIT 1; $f$$q$,
  'DROP POLICY IF EXISTS "Authenticated users can do everything on snapshots" ON public.snapshot',
  'CREATE POLICY snapshot_own_agency ON public.snapshot FOR ALL TO authenticated USING (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id())) WITH CHECK (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()))',
  'DROP POLICY IF EXISTS "Authenticated users can do everything on candidates" ON public.candidate',
  'CREATE POLICY candidate_own_agency ON public.candidate FOR ALL TO authenticated USING (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id())) WITH CHECK (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()))'
]),
('20260728000002', '019_b1_ms1_revoke_rls_exempt_privileges', ARRAY[
  'REVOKE TRUNCATE, REFERENCES ON TABLE public.agency_config, public.agency_rule_override, public.candidate, public.coverage_rule_master, public.csv_import_session, public.flood_zone_master, public.insurance_category, public.insurance_line, public.intent_confirmation, public.restriction_reason_master, public.run_participant, public.snapshot FROM anon, authenticated',
  'REVOKE MAINTAIN ON TABLE public.agency_config, public.agency_rule_override, public.audit_event, public.candidate, public.coverage_rule_master, public.csv_import_session, public.flood_zone_master, public.insurance_category, public.insurance_line, public.intent_confirmation, public.operator, public.property_profile, public.restriction_reason_master, public.run, public.run_participant, public.snapshot FROM anon, authenticated'
]),
('20260728000003', '020_b1_ms1_force_rls_all_tables_and_schema_inventory', ARRAY[
  'ALTER TABLE public.agency_config, public.agency_rule_override, public.audit_event, public.candidate, public.coverage_rule_master, public.csv_import_session, public.flood_zone_master, public.insurance_category, public.insurance_line, public.intent_confirmation, public.operator, public.property_profile, public.restriction_reason_master, public.run, public.run_participant, public.snapshot FORCE ROW LEVEL SECURITY'
]),
('20260728000004', '021_b1_ms1_operator_column_restricted_update', ARRAY[
  'REVOKE UPDATE ON TABLE public.operator FROM authenticated',
  'GRANT UPDATE (name, email, license_number, license_valid_until, updated_at) ON TABLE public.operator TO authenticated'
]),
('20260728000005', '022_b1_ms1_default_privileges_public_schema', ARRAY[
  'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated',
  'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated',
  'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated',
  'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM PUBLIC'
])
ON CONFLICT (version) DO NOTHING;

-- 実行後の確認結果（2026-07-29実測）:
-- 台帳が 012, 013, 014, 016, 017, 018, 019, 020, 021, 022 の順で連続していることを確認。
