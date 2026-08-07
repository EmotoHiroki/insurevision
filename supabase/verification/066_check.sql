-- ============================================================================
-- 066_check.sql
--
-- migration 066（service_roleのテーブル権限を許可リストへ揃えるREVOKE）が
-- 適用済みであることを、第三者が再実行して確認するための読み取り専用SQL。
--
-- 本ファイルはデータを一切変更しない。カタログのみを参照する。
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/066_check.sql
-- 期待する結果: 例外が発生せず、最後に NOTICE が1件出力される。
-- ============================================================================

DO $$
DECLARE
    v_table text;
    v_extra text;
    v_count int;
BEGIN
    -- ── 1. run・run_proof 以外の16表は、service_roleへの権限が0件であること ──
    FOR v_table IN
        SELECT unnest(ARRAY[
            'agency_config', 'agency_rule_override', 'audit_event', 'candidate',
            'coverage_rule_master', 'csv_import_session', 'flood_zone_master',
            'insurance_category', 'insurance_line', 'intent_confirmation',
            'operator', 'property_profile', 'restriction_reason_master',
            'run_participant', 'smartphone_confirm_token', 'snapshot'
        ])
    LOOP
        SELECT count(*) INTO v_count
          FROM information_schema.role_table_grants
         WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name = v_table;
        IF v_count <> 0 THEN
            RAISE EXCEPTION '066 verify failed: service_role still has % grant(s) on public.%', v_count, v_table;
        END IF;
    END LOOP;

    -- ── 2. public.run は SELECT のみであること ─────────────────────────────
    SELECT string_agg(privilege_type, ',' ORDER BY privilege_type) INTO v_extra
      FROM information_schema.role_table_grants
     WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name = 'run';
    IF v_extra IS DISTINCT FROM 'SELECT' THEN
        RAISE EXCEPTION '066 verify failed: service_role privileges on public.run are % (expected SELECT only)', coalesce(v_extra, '(none)');
    END IF;

    -- ── 3. public.run_proof は SELECT・UPDATE のみであること ───────────────
    SELECT string_agg(privilege_type, ',' ORDER BY privilege_type) INTO v_extra
      FROM information_schema.role_table_grants
     WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name = 'run_proof';
    IF v_extra IS DISTINCT FROM 'SELECT,UPDATE' THEN
        RAISE EXCEPTION '066 verify failed: service_role privileges on public.run_proof are % (expected SELECT,UPDATE only)', coalesce(v_extra, '(none)');
    END IF;

    -- ── 4. 検証処理が実際に必要とする権限は失われていないこと ───────────────
    IF NOT has_table_privilege('service_role', 'public.run', 'SELECT') THEN
        RAISE EXCEPTION '066 verify failed: service_role lost SELECT on public.run';
    END IF;
    IF NOT has_table_privilege('service_role', 'public.run_proof', 'SELECT')
       OR NOT has_table_privilege('service_role', 'public.run_proof', 'UPDATE') THEN
        RAISE EXCEPTION '066 verify failed: service_role lost SELECT/UPDATE on public.run_proof';
    END IF;

    RAISE NOTICE '066 verify passed: service_role table grants on the public schema match the 064 allowlist exactly';
END;
$$;
