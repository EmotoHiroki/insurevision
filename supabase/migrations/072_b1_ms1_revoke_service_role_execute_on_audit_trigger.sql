-- ============================================================================
-- 072_b1_ms1_revoke_service_role_execute_on_audit_trigger.sql
--
-- migration 071 の適用により生じた、service_role への意図しない EXECUTE 付与の是正。
--
-- 【何が起きたか】
--   071で新設した `record_run_suspension_audit()` について、071は
--     REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated;
--   のみを行い、**service_role を対象に含めていなかった**。
--
--   本番 `ytpaklotlgrbslshjggc` には、Supabaseがプロジェクト作成時に設定した
--   既定権限（`pg_default_acl`）が残っており、public スキーマへ新しく作成した
--   関数へ service_role の EXECUTE が**自動的に付与**される。
--   その結果、071適用直後の本番では次のようになっていた。
--
--     本番       : {postgres=X/postgres,service_role=X/postgres}  → 実行可能
--     検証環境   : {postgres=X/postgres}                          → 実行不可
--
--   検証環境には当該既定権限が無いため自動付与が発生せず、両DBの定義比較で
--   `function_grant_service` 分類のみ差分として検出された（他11分類は一致）。
--
-- 【なぜ是正が必要か】
--   066・067で service_role が EXECUTE できる public 関数を
--   `record_verified_proof_hash` と `get_proof_object_version` の2件へ
--   許可リスト化している。本件により本番だけ3件となり、
--   `supabase/verification/067_check.sql` が失敗する状態であった。
--   また `record_run_suspension_audit()` はトリガー専用関数であり、
--   いずれのロールからも直接実行される必要がない。
--
--   これは田島様が判断事項1で指摘された
--   「service_role への不要な自動付与が発生しないこと」そのものであり、
--   既定権限（`pg_default_acl`）の整理が未適用であることに起因する。
--   既定権限そのものの是正はご承認済みの別作業として実施する。
--   本migrationは、今回追加した関数について発生した付与のみを取り消す。
--
-- 【本migrationで行うこと】
--   `record_run_suspension_audit()` の EXECUTE を service_role からも剥奪する。
--   REVOKE は付与が無い場合でもエラーにならないため、既定権限を持たない
--   新規DB（自動付与が発生しない環境）へ通し適用しても同じ最終状態になる。
--
-- 既存migrationは編集していない。本ファイルのみを追加する。
-- ============================================================================

REVOKE EXECUTE ON FUNCTION public.record_run_suspension_audit()
    FROM PUBLIC, anon, authenticated, service_role;


-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE
    v_oid   oid;
    v_count int;
    v_extra text;
BEGIN
    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='record_run_suspension_audit';
    IF v_oid IS NULL THEN
        RAISE EXCEPTION '072 failed: record_run_suspension_audit not found';
    END IF;

    -- 1. 当該関数はどのアプリケーションロールからも実行できないこと
    IF has_function_privilege('service_role', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR has_function_privilege('anon', v_oid, 'EXECUTE')
    THEN
        RAISE EXCEPTION '072 failed: record_run_suspension_audit is still executable by an application role';
    END IF;

    -- 2. service_role がEXECUTEできる public 関数は、066・067で許可した2件のみであること
    --    （067_check.sql と同じ判定をmigration側でも行う）
    SELECT count(*), coalesce(string_agg(p.proname, ', '), '(none)')
      INTO v_count, v_extra
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND has_function_privilege('service_role', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('record_verified_proof_hash', 'get_proof_object_version');
    IF v_count <> 0 THEN
        RAISE EXCEPTION '072 failed: service_role can still EXECUTE % unexpected function(s): %', v_count, v_extra;
    END IF;

    -- 3. 検証処理が必要とする2関数のEXECUTEは失われていないこと
    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='record_verified_proof_hash';
    IF v_oid IS NULL OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '072 failed: service_role lost EXECUTE on record_verified_proof_hash';
    END IF;
    SELECT oid INTO v_oid FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='get_proof_object_version';
    IF v_oid IS NULL OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '072 failed: service_role lost EXECUTE on get_proof_object_version';
    END IF;

    -- 4. トリガーが接続されたままであること（剥奪が動作へ影響していないこと）
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
         WHERE NOT t.tgisinternal
           AND c.relname = 'run'
           AND t.tgname  = 'trg_run_suspension_audit'
    ) THEN
        RAISE EXCEPTION '072 failed: trg_run_suspension_audit is no longer attached to public.run';
    END IF;

    RAISE NOTICE '072: service_role EXECUTE on record_run_suspension_audit revoked; the allowlist is back to the two permitted functions';
END;
$selfcheck$;
