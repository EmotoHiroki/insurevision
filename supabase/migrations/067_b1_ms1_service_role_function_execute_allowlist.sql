-- ============================================================================
-- 067_b1_ms1_service_role_function_execute_allowlist.sql
--
-- 066でservice_roleのテーブル権限を許可リストへ揃えた際、あわせて残っていた
-- 関数EXECUTE権限の既定付与も点検した。本番のservice_roleは、064・065が
-- 明示する2関数（record_verified_proof_hash・get_proof_object_version）以外にも、
-- publicスキーマの関数25件をSupabaseの既定権限によりEXECUTEできる状態だった。
--
-- 【調査結果】
--   service_roleキーを実際に使用しているのはEdge Function verify-proofのみで、
--   呼び出しているのは record_verified_proof_hash と get_proof_object_version の
--   2関数だけである（supabase/functions/verify-proof/index.ts）。
--   残る25関数は、認証済み利用者のJWT（authenticated）経由でのみ呼び出される
--   設計であり、内部で auth.uid() から operator を解決する検査を持つため、
--   service_role で呼び出しても意味を成さない。
--
--   田島様のご指示「権限まで含めて再現可能な配置手順とし、MS1内で対応」に
--   従い、066のテーブル権限と同様に、関数EXECUTE権限も
--   実際に必要な2関数のみへ絞る。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

DO $revoke$
DECLARE
    v_fn record;
BEGIN
    FOR v_fn IN
        SELECT p.oid, p.proname
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND has_function_privilege('service_role', p.oid, 'EXECUTE')
           AND p.proname NOT IN ('record_verified_proof_hash', 'get_proof_object_version')
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM service_role',
                        'public', v_fn.proname, pg_get_function_identity_arguments(v_fn.oid));
    END LOOP;
END;
$revoke$;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE
    v_count int;
    v_extra text;
BEGIN
    SELECT count(*), string_agg(p.proname, ', ') INTO v_count, v_extra
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND has_function_privilege('service_role', p.oid, 'EXECUTE')
       AND p.proname NOT IN ('record_verified_proof_hash', 'get_proof_object_version');
    IF v_count <> 0 THEN
        RAISE EXCEPTION '067 failed: service_role can still EXECUTE % unexpected function(s): %', v_count, v_extra;
    END IF;

    IF NOT has_function_privilege('service_role',
            (SELECT oid FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='record_verified_proof_hash'),
            'EXECUTE') THEN
        RAISE EXCEPTION '067 failed: service_role lost EXECUTE on record_verified_proof_hash';
    END IF;
    IF NOT has_function_privilege('service_role',
            (SELECT oid FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='get_proof_object_version'),
            'EXECUTE') THEN
        RAISE EXCEPTION '067 failed: service_role lost EXECUTE on get_proof_object_version';
    END IF;

    RAISE NOTICE '067: service_role can EXECUTE exactly 2 public-schema functions (record_verified_proof_hash, get_proof_object_version)';
END;
$selfcheck$;
