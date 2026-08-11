-- ============================================================================
-- 073_b1_ms1_suspension_audit_scope_to_authenticated.sql
--
-- migration 071 で新設した保留・再開の監査トリガーが、
-- アプリ利用者以外の経路（postgres・service_role 等）による保留・再開を
-- 一律に拒否してしまう不具合の是正。
--
-- 【何が起きたか】
--   071の `record_run_suspension_audit()` は、`auth.uid()` から有効な operator を
--   解決できない場合に無条件で例外を送出していた。
--   その結果、`supabase/verification/runtime_setup.sql`（実HTTP検証42項目の
--   前提データを作成する既存スクリプト）が、保留中の run を検査用に作成する箇所で
--   次のエラーとなり失敗した。
--
--     run: suspend/resume requires an identifiable active operator so the change
--          can be audited (run 00000000-0000-0000-0000-0000000000f2)
--
--   本スクリプトは postgres として実行されるため `auth.uid()` は NULL であり、
--   operator を解決できないためである。
--
-- 【なぜ当初の実装が誤りか】
--   「記録の無い保留・再開を発生させない」という意図自体は妥当だが、
--   その保証が必要なのは**アプリ利用者（authenticated）の操作**である。
--   postgres は BYPASSRLS を持ち、トリガーの無効化も可能であるため、
--   postgres を拒否しても実効的な保護にはならない一方、
--   検証データの整備や運用上のデータ修復といった正当な経路を塞いでしまう。
--
--   本リポジトリの他の防御（`enforce_run_finalize_lockdown` 等）は、いずれも
--   `IF current_user = 'authenticated' THEN` で適用範囲を明示している。
--   071だけがこの原則から外れていた。
--
-- 【本migrationで行うこと】
--   適用範囲を既存の原則へ揃える。
--     ・operator を解決できた場合          → 従来どおり audit_event へ記録する
--     ・解決できず、かつ authenticated     → 例外（アプリ利用者の操作は必ず記録する）
--     ・解決できず、authenticated 以外      → 記録せずに通す（管理経路）
--
--   これにより、アプリ利用者による保留・再開が記録なしで成立することは
--   引き続きあり得ない。田島様2026-08-10ご指摘②の要件は維持される。
--
-- 既存migrationは編集していない。本ファイルのみを追加する。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_run_suspension_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_operator_id uuid;
    v_event_type  text;
    v_payload     jsonb;
BEGIN
    IF OLD.run_status IS NOT DISTINCT FROM NEW.run_status THEN
        RETURN NULL;
    END IF;

    IF NEW.run_status = 'suspended' THEN
        v_event_type := 'run_suspended';
        v_payload := jsonb_build_object(
            'previous_run_status', OLD.run_status,
            'new_run_status',      NEW.run_status,
            'suspension_type',     NEW.suspension_type,
            'pending_note',        NEW.pending_note,
            'suspended_at',        NEW.suspended_at
        );
    ELSIF OLD.run_status = 'suspended' THEN
        v_event_type := 'run_resumed';
        v_payload := jsonb_build_object(
            'previous_run_status', OLD.run_status,
            'new_run_status',      NEW.run_status,
            'suspension_type',     OLD.suspension_type,
            'pending_note',        OLD.pending_note,
            'suspended_at',        OLD.suspended_at
        );
    ELSE
        -- 保留・再開以外の遷移は本トリガーの対象外
        RETURN NULL;
    END IF;

    -- 操作者は呼出し元のセッションから導出する（引数を信用しない）
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        -- migration 073: 適用範囲をアプリ利用者へ限定する。
        -- authenticated の操作は必ず記録できなければならない（記録なしの保留・再開を作らない）。
        IF current_user = 'authenticated' THEN
            RAISE EXCEPTION
              'run: suspend/resume requires an identifiable active operator so the change can be audited (run %)',
              NEW.id;
        END IF;
        -- postgres・service_role 等の管理経路は記録せずに通す。
        -- これらはBYPASSRLSやトリガー無効化が可能であり、拒否しても保護にならない一方、
        -- 検証データの整備や運用上のデータ修復を不能にしてしまうため。
        RETURN NULL;
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (NEW.id, v_event_type, v_operator_id, v_payload);

    RETURN NULL;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.record_run_suspension_audit()
    FROM PUBLIC, anon, authenticated, service_role;


-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE
    v_src text;
    v_oid oid;
BEGIN
    SELECT prosrc, oid INTO v_src, v_oid FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='record_run_suspension_audit';
    IF v_src IS NULL THEN
        RAISE EXCEPTION '073 failed: record_run_suspension_audit not found';
    END IF;

    -- authenticated に対する強制が残っていること
    IF v_src NOT LIKE '%current_user = ''authenticated''%'
       OR v_src NOT LIKE '%requires an identifiable active operator%'
    THEN
        RAISE EXCEPTION '073 failed: the authenticated-path requirement was lost';
    END IF;

    -- SECURITY DEFINER と search_path が維持されていること
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc
         WHERE oid = v_oid AND prosecdef
           AND array_to_string(proconfig, ',') LIKE '%search_path=%'
    ) THEN
        RAISE EXCEPTION '073 failed: SECURITY DEFINER / search_path was lost';
    END IF;

    -- どのアプリケーションロールからも直接実行できないこと
    IF has_function_privilege('service_role', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR has_function_privilege('anon', v_oid, 'EXECUTE')
    THEN
        RAISE EXCEPTION '073 failed: the function is executable by an application role';
    END IF;

    -- トリガーが接続されたままであること
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
         WHERE NOT t.tgisinternal AND c.relname='run' AND t.tgname='trg_run_suspension_audit'
    ) THEN
        RAISE EXCEPTION '073 failed: trg_run_suspension_audit is no longer attached to public.run';
    END IF;

    RAISE NOTICE '073: suspend/resume auditing is now enforced for authenticated only; administrative paths pass without a record';
END;
$selfcheck$;
