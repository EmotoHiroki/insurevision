-- ============================================================================
-- 074_b1_ms1_default_privileges_service_role_revoke.sql
--
-- 田島様 判断事項1（既定権限 `pg_default_acl` の整理）への対応。
--
-- 【ご判断の内容】
--   既定権限を検証環境へ先に適用し、`service_role` への不要な自動付与が
--   発生しないことを失敗条件として確認してから本番へ適用すること。
--   `supabase_admin` 所有分は今回の変更対象とせず、残存を明示すること。
--
-- 【なぜ必要か（実際に事故が起きている）】
--   本対応が未適用であったために、migration 071 で新設した
--   `record_run_suspension_audit()` へ、本番でのみ `service_role` の EXECUTE が
--   **自動的に付与**された。066・067で2件へ許可リスト化した状態から本番だけが
--   逸脱し、`verification/067_check.sql` が失敗する状態となった（072で個別に是正）。
--   個別の是正は「作るたびに剥奪し忘れる」余地を残すため、
--   既定付与そのものを止める本対応が根本的な解決となる。
--
-- 【本migrationで行うこと】
--   所有ロール postgres がスキーマ public に作成する将来のオブジェクトについて、
--   `service_role` への既定付与を停止する（別紙「既定権限の現状整理と変更案」§4.1）。
--
--   ・既存オブジェクトには影響しない（既存分は066・067で対応済み）
--   ・今後サーバー側処理が新しい関数・テーブルを必要とする場合は、
--     migration内で明示的に GRANT する。許可リスト方式の意図した動作である。
--   ・`supabase_admin` 所有の既定権限は本migrationの対象外であり、残存する。
--     これは Supabase 側が管理する領域であり、当方の migration で変更すべきでないため。
--     残存状況は別紙§3に記載のとおりである。
--
-- 適用順序: 検証環境 `uwwrtrzhyjormwfyvmrg` へ先に適用し、
--           新規オブジェクト作成時に service_role への自動付与が発生しないことを
--           確認したうえで本番 `ytpaklotlgrbslshjggc` へ適用する。
--
-- 既存migrationは編集していない。本ファイルのみを追加する。
-- ============================================================================

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON TABLES    FROM service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON FUNCTIONS FROM service_role;


-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
-- 「新しく作ったオブジェクトへ service_role の権限が自動付与されないこと」を、
-- 実際に一時オブジェクトを作成して確認する（失敗条件つきの検査）。
-- 検査用オブジェクトは同一トランザクション内で必ず削除する。
DO $selfcheck$
DECLARE
    v_tbl_granted  boolean;
    v_fn_granted   boolean;
    v_residual     text;
BEGIN
    -- 1. postgres 所有の public 向け既定権限に service_role が残っていないこと
    SELECT string_agg(d.defaclacl::text, ' | ')
      INTO v_residual
      FROM pg_default_acl d
      JOIN pg_namespace n ON n.oid = d.defaclnamespace
      JOIN pg_roles r     ON r.oid = d.defaclrole
     WHERE n.nspname = 'public'
       AND r.rolname = 'postgres'
       AND d.defaclacl::text LIKE '%service_role%';
    IF v_residual IS NOT NULL THEN
        RAISE EXCEPTION '074 failed: postgres/public default privileges still reference service_role -> %', v_residual;
    END IF;

    -- 2. 実際に新規オブジェクトを作成し、自動付与が起きないことを確認する
    CREATE TABLE public.zz_074_default_acl_probe (id int);
    CREATE FUNCTION public.zz_074_default_acl_probe_fn() RETURNS int
      LANGUAGE sql IMMUTABLE AS $probe$ SELECT 1 $probe$;

    v_tbl_granted := has_table_privilege('service_role', 'public.zz_074_default_acl_probe', 'SELECT');
    v_fn_granted  := has_function_privilege('service_role', 'public.zz_074_default_acl_probe_fn()', 'EXECUTE');

    DROP FUNCTION public.zz_074_default_acl_probe_fn();
    DROP TABLE public.zz_074_default_acl_probe;

    IF v_tbl_granted THEN
        RAISE EXCEPTION '074 failed: a newly created table was still auto-granted to service_role';
    END IF;
    IF v_fn_granted THEN
        RAISE EXCEPTION '074 failed: a newly created function was still auto-granted to service_role';
    END IF;

    -- 3. 検査用オブジェクトが残っていないこと
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'zz_074_default_acl_probe')
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'zz_074_default_acl_probe_fn')
    THEN
        RAISE EXCEPTION '074 failed: probe objects were not removed';
    END IF;

    -- 4. 066・067で許可した2関数のEXECUTEは失われていないこと（既存分への非影響）
    IF NOT has_function_privilege('service_role', 'public.record_verified_proof_hash(uuid, text, bigint, text)', 'EXECUTE')
       OR NOT has_function_privilege('service_role', 'public.get_proof_object_version(uuid)', 'EXECUTE')
    THEN
        RAISE EXCEPTION '074 failed: service_role lost EXECUTE on a permitted function';
    END IF;

    RAISE NOTICE '074: service_role is no longer auto-granted on new objects in public; existing allowlist is intact';
END;
$selfcheck$;
