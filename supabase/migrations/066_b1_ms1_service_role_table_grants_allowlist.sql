-- ============================================================================
-- 066_b1_ms1_service_role_table_grants_allowlist.sql
--
-- 田島様2026-08-07ご指摘（GRANT再現性）への対応。
--
-- 【ご指摘の内容】
--   「権限まで含めて再現可能な配置手順とし、MS1内で対応する」ことは
--   既に決定済みの方針である。service_roleのテーブル権限126件のうち
--   123件がSupabaseの既定権限による自動付与のまま残っている状態は、
--   許容可否を問う対象ではなく、未達として次のいずれかで解消する。
--     ・必要な権限をmigrationへ明示し、新規DBと本番を一致させる
--     ・本番の不要な権限をREVOKEし、本番を最小権限へ合わせる
--
-- 【調査結果】
--   本番でservice_roleキーを実際に使用しているのは、
--   Edge Function verify-proof（migration 064・065）のみである。
--   その処理が public スキーマに対して行うのは次の2点だけで、
--   これは既に064で明示的に付与済みである。
--     public.run       … SELECT のみ（対象runの状態確認）
--     public.run_proof … SELECT・UPDATE（登録済み証跡の参照と検証結果の記録）
--   リポジトリ全体を確認したが、上記以外にservice_roleキーで
--   publicスキーマのテーブルへ書込みを行う本番稼働中の経路は無い。
--   （docs-unified/scripts/create_ms2_fixtures.js はMS2検証用の使い捨てスクリプトで
--    デプロイ済みアプリからは呼び出されない。本番の標準権限には含めない）
--
--   したがって、public.run・public.run_proof 以外の16表、および
--   この2表に残る不要な権限（INSERT・DELETE・TRUNCATE・REFERENCES・TRIGGER、
--   および run_proof のSELECT・UPDATE以外）は、Supabaseの既定権限による
--   自動付与がそのまま残っているだけで、実際に使用されていない。
--   最小権限の原則に従い、本番側をREVOKEして064の許可リストに一致させる。
--
-- 【対象外（既定ACLそのものと storage スキーマ）】
--   本migrationは public スキーマの既存18表への現在の付与のみを是正する。
--   ・pg_default_acl（今後作成される新規テーブルへの自動付与の仕組みそのもの）は
--     Supabaseのプロジェクト初期設定であり、本migrationでは変更しない。
--   ・storage.objects への service_role 権限は、Supabase Storage基盤自体が
--     内部的に必要とする可能性があるため、対象外とする
--     （service_roleが検証処理に必要とするSELECT・UPDATEは064で確認済み）。
--   ・run-pdfs バケットは0オブジェクト・ソース参照0件であり、別途ご判断待ち。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

DO $revoke$
DECLARE
    v_table text;
BEGIN
    FOR v_table IN
        SELECT unnest(ARRAY[
            'agency_config', 'agency_rule_override', 'audit_event', 'candidate',
            'coverage_rule_master', 'csv_import_session', 'flood_zone_master',
            'insurance_category', 'insurance_line', 'intent_confirmation',
            'operator', 'property_profile', 'restriction_reason_master',
            'run', 'run_participant', 'run_proof', 'smartphone_confirm_token',
            'snapshot'
        ])
    LOOP
        EXECUTE format('REVOKE ALL PRIVILEGES ON TABLE public.%I FROM service_role', v_table);
    END LOOP;
END;
$revoke$;

-- 064で付与した許可リストのみを再度明示する（上のREVOKE ALLで一度落ちるため）。
GRANT SELECT         ON TABLE public.run       TO service_role;
GRANT SELECT, UPDATE  ON TABLE public.run_proof TO service_role;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE
    v_table  text;
    v_extra  text;
    v_count  int;
BEGIN
    -- 1. run・run_proof 以外の16表は、service_roleへの権限が0件であること
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
            RAISE EXCEPTION '066 failed: service_role still has % grant(s) on public.%', v_count, v_table;
        END IF;
    END LOOP;

    -- 2. public.run は SELECT のみであること
    SELECT string_agg(privilege_type, ',' ORDER BY privilege_type) INTO v_extra
      FROM information_schema.role_table_grants
     WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name = 'run';
    IF v_extra IS DISTINCT FROM 'SELECT' THEN
        RAISE EXCEPTION '066 failed: service_role privileges on public.run are % (expected SELECT only)', coalesce(v_extra, '(none)');
    END IF;

    -- 3. public.run_proof は SELECT・UPDATE のみであること
    SELECT string_agg(privilege_type, ',' ORDER BY privilege_type) INTO v_extra
      FROM information_schema.role_table_grants
     WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name = 'run_proof';
    IF v_extra IS DISTINCT FROM 'SELECT,UPDATE' THEN
        RAISE EXCEPTION '066 failed: service_role privileges on public.run_proof are % (expected SELECT,UPDATE only)', coalesce(v_extra, '(none)');
    END IF;

    -- 4. service_role が実際に必要とする権限は失われていないこと（064の確認を再掲）
    IF NOT has_table_privilege('service_role', 'public.run', 'SELECT') THEN
        RAISE EXCEPTION '066 failed: service_role lost SELECT on public.run';
    END IF;
    IF NOT has_table_privilege('service_role', 'public.run_proof', 'SELECT')
       OR NOT has_table_privilege('service_role', 'public.run_proof', 'UPDATE') THEN
        RAISE EXCEPTION '066 failed: service_role lost SELECT/UPDATE on public.run_proof';
    END IF;

    RAISE NOTICE '066: service_role table grants on the public schema now match the 064 allowlist exactly (SELECT run; SELECT,UPDATE run_proof)';
END;
$selfcheck$;
