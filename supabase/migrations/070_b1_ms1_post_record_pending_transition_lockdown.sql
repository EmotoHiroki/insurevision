-- ============================================================================
-- 070_b1_ms1_post_record_pending_transition_lockdown.sql
--
-- 田島様2026-08-11ご判断（2026-08-10ご指摘①への回答）への対応。
--
-- 【ご判断の内容】
--   状態遷移は案B（post_record_pending から suspended への遷移を不許可へ戻す）を採用。
--   あわせて、次のとおりご指示をいただいた。
--     ・post_record_pending では保留ボタンを表示しない
--     ・post_record_pending から draft へ戻す画面操作は追加しない
--     ・現在DB側で許可されている post_record_pending → draft の遷移も、
--       既存の利用経路がないことを確認したうえで不許可とする
--       （draft へ戻すとスマホ確認3操作が再び実行可能となり、状態ごとの
--         操作範囲が広がる一方、当該戻し操作自体の監査記録が無いため）
--     ・draft → suspended、suspended → draft の承認済み経路は維持する
--
-- 【既存の利用経路の確認（実装前に実施。ご指示に基づく）】
--   post_record_pending → draft を行う経路はソース全体に存在しないことを確認した。
--     ・src/ 内で run.run_status を更新する箇所は4件のみ。
--         'suspended'（保留）／'draft'（suspended からの再開のみ）／
--         'post_record_pending'（事後記録フェーズ1完了）／'archived'（確定後）
--       このうち 'draft' を書き込むのは再開処理だけで、保留中の run にのみ到達する。
--     ・src/app/api/ 配下で run_status を更新する箇所は0件（参照のみ）。
--     ・DB関数が run_status を書き込むのは finalize_run 系統の 'finalized' のみ。
--       'draft' を書き込む関数は存在しない。
--   したがって本migrationによる不許可化で失われる既存経路は無い。
--
-- 【本migrationで行うこと】
--   1. authenticated による直接UPDATEの許可リストから、次の2組を削除する。
--        post_record_pending -> suspended   （068で承認を得ずに許可していたもの）
--        post_record_pending -> draft
--   2. suspended へ入る際の必須項目に pending_note を加え、保留3項目すべてを
--      必須とする（田島様2026-08-10ご指摘②）。
--      068は「画面が空欄を許容しているため任意」としていたが、画面側も同時に
--      未入力を許容しない形へ変更する。
--
--   適用後に許可される遷移（authenticated）:
--     draft               -> post_record_pending
--     draft               -> suspended            （保留3項目すべて必須）
--     suspended           -> draft                （保留3列のクリア必須。056で実装済み）
--     finalized           -> archived             （run_status のみ変更可。056で実装済み）
--   拒否される遷移（本migrationで追加される分）:
--     post_record_pending -> suspended            ★本migrationで拒否
--     post_record_pending -> draft                ★本migrationで拒否
--
--   post_record_pending からは finalize_run() による確定のみが可能となる。
--   finalize_run() は SECURITY DEFINER で current_user が postgres となるため、
--   本許可リストの対象外である（確定は従来どおり関数経由でのみ成立する）。
--
-- 既存migrationは編集していない。本ファイルのみを追加する。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO ''
AS $function$
DECLARE
    v_new_normalized public.run;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF current_user = 'authenticated' THEN
            IF NEW.run_status IS DISTINCT FROM 'draft' THEN
                RAISE EXCEPTION 'run: new rows must be created with run_status=''draft'' (attempted %)', NEW.run_status;
            END IF;
            IF NEW.finalized_at IS NOT NULL OR NEW.finalized_by IS NOT NULL
               OR NEW.pdf_object_key IS NOT NULL OR NEW.pdf_sha256 IS NOT NULL
               OR (NEW.export_status IS NOT NULL AND NEW.export_status <> 'pending')
            THEN
                RAISE EXCEPTION 'run: finalize-owned fields cannot be set on insert, only via finalize_run()';
            END IF;
            IF NEW.compare_presented_at IS NOT NULL THEN
                RAISE EXCEPTION 'run: compare_presented_at cannot be set on insert, only via record_compare_presented()';
            END IF;
            IF NEW.recruiter_smartphone_confirmed_at IS NOT NULL
               OR NEW.customer_smartphone_confirmed_at IS NOT NULL
            THEN
                RAISE EXCEPTION 'run: smartphone confirmation fields cannot be set on insert';
            END IF;
            IF NEW.recommended_candidate_id IS NOT NULL OR NEW.decided_candidate_id IS NOT NULL
               OR NEW.plan_diff_reason IS NOT NULL OR NEW.plan_diff_reason_recorded_at IS NOT NULL
            THEN
                RAISE EXCEPTION 'run: plan selection fields cannot be set on insert';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    -- TG_OP = 'UPDATE'
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized'
       AND NEW.run_status IS DISTINCT FROM 'archived'
    THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    IF OLD.run_status = 'archived' AND NEW.run_status IS DISTINCT FROM 'archived' THEN
        RAISE EXCEPTION 'run: cannot transition out of archived state (run %)', OLD.id;
    END IF;

    IF current_user = 'authenticated' THEN
        IF OLD.run_status = 'finalized' THEN
            IF NEW.run_status = 'archived' THEN
                v_new_normalized := NEW;
                v_new_normalized.run_status := OLD.run_status;
                v_new_normalized.updated_at := OLD.updated_at;
                IF v_new_normalized IS DISTINCT FROM OLD THEN
                    RAISE EXCEPTION 'run: only run_status may change when archiving a finalized run (run %)', OLD.id;
                END IF;
                RETURN NEW;
            END IF;
            RAISE EXCEPTION 'run: row is already finalized, no further direct modification permitted (run %)', OLD.id;
        END IF;

        IF OLD.run_status = 'archived' THEN
            RAISE EXCEPTION 'run: row is archived, no further direct modification permitted (run %)', OLD.id;
        END IF;

        -- migration 056: 保留中は「再開操作」以外を一切許可しない。
        -- 再開＝run_statusをdraftへ戻し、保留3列をクリアする操作のみ。
        IF OLD.run_status = 'suspended' THEN
            IF NEW.run_status = 'draft' THEN
                IF NEW.suspension_type IS NOT NULL
                   OR NEW.pending_note IS NOT NULL
                   OR NEW.suspended_at IS NOT NULL
                THEN
                    RAISE EXCEPTION 'run: resuming a suspended run must clear suspension_type, pending_note and suspended_at (run %)', OLD.id;
                END IF;
                v_new_normalized := NEW;
                v_new_normalized.run_status      := OLD.run_status;
                v_new_normalized.suspension_type := OLD.suspension_type;
                v_new_normalized.pending_note    := OLD.pending_note;
                v_new_normalized.suspended_at    := OLD.suspended_at;
                v_new_normalized.updated_at      := OLD.updated_at;
                IF v_new_normalized IS DISTINCT FROM OLD THEN
                    RAISE EXCEPTION 'run: only the resume operation may modify a suspended run (run %)', OLD.id;
                END IF;
                RETURN NEW;
            END IF;
            RAISE EXCEPTION 'run: row is suspended, only the resume operation is permitted (run %)', OLD.id;
        END IF;

        IF NEW.run_status = 'finalized' THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
        END IF;

        -- ── migration 070: 許可リストから post_record_pending 始点の2組を削除 ──
        -- ここへ到達する時点で OLD.run_status は draft か post_record_pending。
        -- 068では post_record_pending -> draft / -> suspended を許可していたが、
        -- 田島様2026-08-11のご判断により、いずれも不許可へ戻す。
        -- post_record_pending からは finalize_run() による確定のみが可能となる。
        IF NEW.run_status IS DISTINCT FROM OLD.run_status THEN
            IF NOT (
                   (OLD.run_status = 'draft' AND NEW.run_status = 'post_record_pending')
                OR (OLD.run_status = 'draft' AND NEW.run_status = 'suspended')
            ) THEN
                RAISE EXCEPTION 'run: transition from % to % is not permitted (run %)',
                    OLD.run_status, NEW.run_status, OLD.id;
            END IF;

            -- migration 070: 保留へ入る場合は保留3項目すべての記録を必須とする。
            -- 068では pending_note のみ任意としていたが、
            -- 田島様2026-08-10ご指摘②により3項目すべてを必須へ改める。
            IF NEW.run_status = 'suspended' THEN
                IF NEW.suspension_type IS NULL
                   OR NEW.suspended_at IS NULL
                   OR NEW.pending_note IS NULL
                   OR btrim(NEW.pending_note) = ''
                THEN
                    RAISE EXCEPTION 'run: suspending a run requires suspension_type, pending_note and suspended_at to be recorded (run %)', OLD.id;
                END IF;
            END IF;
        END IF;

        IF NEW.finalized_at   IS DISTINCT FROM OLD.finalized_at
           OR NEW.finalized_by   IS DISTINCT FROM OLD.finalized_by
           OR NEW.pdf_object_key IS DISTINCT FROM OLD.pdf_object_key
           OR NEW.pdf_sha256     IS DISTINCT FROM OLD.pdf_sha256
           OR NEW.export_status  IS DISTINCT FROM OLD.export_status
        THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
        END IF;

        IF NEW.compare_presented_at IS DISTINCT FROM OLD.compare_presented_at THEN
            RAISE EXCEPTION 'run: compare_presented_at can only be modified via record_compare_presented() (run %)', OLD.id;
        END IF;

        IF NEW.recruiter_smartphone_confirmed_at IS DISTINCT FROM OLD.recruiter_smartphone_confirmed_at
           OR NEW.customer_smartphone_confirmed_at IS DISTINCT FROM OLD.customer_smartphone_confirmed_at
           OR NEW.smartphone_conf_status IS DISTINCT FROM OLD.smartphone_conf_status
        THEN
            RAISE EXCEPTION 'run: smartphone confirmation fields can only be modified via confirm_smartphone() or record_smartphone_manual_confirmation() (run %)', OLD.id;
        END IF;

        IF NEW.recommended_candidate_id IS DISTINCT FROM OLD.recommended_candidate_id
           OR NEW.decided_candidate_id IS DISTINCT FROM OLD.decided_candidate_id
           OR NEW.plan_diff_reason IS DISTINCT FROM OLD.plan_diff_reason
           OR NEW.plan_diff_reason_recorded_at IS DISTINCT FROM OLD.plan_diff_reason_recorded_at
        THEN
            RAISE EXCEPTION 'run: plan selection fields can only be modified via record_plan_selection() (run %)', OLD.id;
        END IF;

        IF NEW.electronic_consent_status      IS DISTINCT FROM OLD.electronic_consent_status
           OR NEW.electronic_consent_method    IS DISTINCT FROM OLD.electronic_consent_method
           OR NEW.electronic_consent_confirmed_at IS DISTINCT FROM OLD.electronic_consent_confirmed_at
           OR NEW.electronic_consent_operator_id  IS DISTINCT FROM OLD.electronic_consent_operator_id
        THEN
            RAISE EXCEPTION 'run: electronic consent fields can only be modified via record_electronic_consent() (run %)', OLD.id;
        END IF;

        IF NEW.paper_confirmation_status IS DISTINCT FROM OLD.paper_confirmation_status
           OR NEW.paper_confirmation_completed_at IS DISTINCT FROM OLD.paper_confirmation_completed_at
        THEN
            RAISE EXCEPTION 'run: paper confirmation fields can only be modified via record_paper_confirmation() (run %)', OLD.id;
        END IF;

        IF NEW.important_matters_delivered IS DISTINCT FROM OLD.important_matters_delivered
           OR NEW.important_matters_delivered_at IS DISTINCT FROM OLD.important_matters_delivered_at
           OR NEW.important_matters_delivery_method IS DISTINCT FROM OLD.important_matters_delivery_method
        THEN
            RAISE EXCEPTION 'run: important matters delivery fields can only be modified via record_important_matters_delivery() (run %)', OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE v_src text;
BEGIN
    SELECT prosrc INTO v_src FROM pg_proc
     WHERE pronamespace='public'::regnamespace AND proname='enforce_run_finalize_lockdown';

    IF v_src IS NULL THEN
        RAISE EXCEPTION '070 failed: enforce_run_finalize_lockdown not found';
    END IF;

    -- post_record_pending 始点の2組が許可リストから消えていること
    IF v_src LIKE '%OLD.run_status = ''post_record_pending'' AND NEW.run_status = ''suspended''%' THEN
        RAISE EXCEPTION '070 failed: post_record_pending -> suspended is still allowlisted';
    END IF;
    IF v_src LIKE '%OLD.run_status = ''post_record_pending'' AND NEW.run_status = ''draft''%' THEN
        RAISE EXCEPTION '070 failed: post_record_pending -> draft is still allowlisted';
    END IF;

    -- 承認済みの2組が残っていること
    IF v_src NOT LIKE '%OLD.run_status = ''draft'' AND NEW.run_status = ''post_record_pending''%'
       OR v_src NOT LIKE '%OLD.run_status = ''draft'' AND NEW.run_status = ''suspended''%'
    THEN
        RAISE EXCEPTION '070 failed: an approved transition was lost from the allowlist';
    END IF;

    -- 保留3項目すべてが必須になっていること
    IF v_src NOT LIKE '%requires suspension_type, pending_note and suspended_at to be recorded%' THEN
        RAISE EXCEPTION '070 failed: pending_note is not required when suspending';
    END IF;

    -- 既存の保護が失われていないこと
    IF v_src NOT LIKE '%cannot transition out of finalized state%'
       OR v_src NOT LIKE '%cannot transition out of archived state%'
       OR v_src NOT LIKE '%only the resume operation is permitted%'
       OR v_src NOT LIKE '%transition from % to % is not permitted%'
    THEN
        RAISE EXCEPTION '070 failed: an existing lockdown branch was lost';
    END IF;

    -- トリガーが run に接続されたままであること
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
         WHERE NOT t.tgisinternal
           AND c.relname = 'run'
           AND t.tgfoid = 'public.enforce_run_finalize_lockdown'::regproc
    ) THEN
        RAISE EXCEPTION '070 failed: the trigger is no longer attached to public.run';
    END IF;

    RAISE NOTICE '070: post_record_pending -> suspended / -> draft are now rejected; suspending requires all three suspension fields';
END;
$selfcheck$;
