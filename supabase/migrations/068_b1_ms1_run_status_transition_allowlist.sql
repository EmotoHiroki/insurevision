-- ============================================================================
-- 068_b1_ms1_run_status_transition_allowlist.sql
--
-- 田島様2026-08-08ご指摘4への対応。
--
-- 【ご指摘の内容】
--   新設した遷移表は「表にない遷移はすべて拒否される」としているが、
--   056のトリガーでは次の遷移が通る実装になっている。
--     ・draft → archived への直接変更
--     ・post_record_pending → archived への直接変更
--     ・post_record_pending → suspended への変更（保留3列の記録を含め）
--   これらを許容する設計とするかについて、業務上の理由を含めて見解を示したうえで、
--   遷移表・実装・肯定否定テストを一致させること。
--
-- 【当方の見解と、その根拠】
--   実装（画面）の意図は次のとおりで、DB側がそれより緩い状態でした。
--
--   1. archived への遷移は「確定済み」からのみとすべきである（＝2件は拒否する）
--      画面のアーカイブ操作は `run_status === 'finalized'` のときにのみ表示される
--      （src/app/run/[id]/page.tsx）。業務上も、archived は
--      「証跡が揃って確定した案件を、以後変更しない状態として閉じる」ことを意味する。
--      draft・post_record_pending から直接 archived にできると、
--      確定ゲート（証跡の登録・実ファイルのSHA-256検証・同意3種・未解決項目0件）を
--      一度も通っていない案件が「以後変更不可」の状態で残る。
--      これは archived の意味を弱め、確定条件を迂回する経路にもなるため、拒否する。
--
--   2. post_record_pending → suspended は許容する（＝1件は許容し、遷移表へ明記する）
--      画面の保留操作は編集可能状態（draft・post_record_pending）で表示される。
--      post_record_pending は「事後記録の完了待ち」であり、
--      その途中で案件を一時停止する業務上の必要は draft と同じく存在する。
--      保留は情報を失う操作ではなく、再開すれば元の編集可能状態へ戻せる。
--      したがって許容し、遷移表にも明記する。
--
-- 【本migrationで行うこと】
--   authenticated による直接UPDATEについて、run_status の遷移を許可リスト化する。
--   あわせて、suspended へ入る際に保留種別と保留日時の記録を必須とする
--   （田島様2026-08-06ご指摘1「保留種別・保留メモ・保留日時の記録は必要」への対応。
--     従来は再開時のクリアのみを強制し、遷移時の記録を強制していなかった）。
--   pending_note は任意項目のままとする（画面が空欄を許容しているため）。
--
--   許可する遷移（authenticated の直接UPDATE）:
--     draft               -> post_record_pending
--     draft               -> suspended            （suspension_type・suspended_at 必須）
--     post_record_pending -> draft
--     post_record_pending -> suspended            （同上）
--     suspended           -> draft                （保留3列のクリア必須。056で実装済み）
--     finalized           -> archived             （run_status のみ変更可。056で実装済み）
--   拒否する遷移:
--     draft               -> archived             ★本migrationで拒否
--     post_record_pending -> archived             ★本migrationで拒否
--     draft/post_record_pending -> finalized      （finalize_run() 経由のみ。056で実装済み）
--     archived            -> 任意                 （056で実装済み）
--
--   finalize_run() は SECURITY DEFINER で current_user が postgres となるため、
--   本許可リストの対象外である（確定は従来どおり関数経由でのみ成立する）。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
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

        -- ── migration 068: run_status の遷移を許可リスト化する ──────────────
        -- ここへ到達する時点で OLD.run_status は draft か post_record_pending。
        -- 従来はこの2状態から archived への直接変更が素通りしており、
        -- 確定ゲートを通らないまま「以後変更不可」の状態を作ることができた。
        IF NEW.run_status IS DISTINCT FROM OLD.run_status THEN
            IF NOT (
                   (OLD.run_status = 'draft'               AND NEW.run_status = 'post_record_pending')
                OR (OLD.run_status = 'draft'               AND NEW.run_status = 'suspended')
                OR (OLD.run_status = 'post_record_pending' AND NEW.run_status = 'draft')
                OR (OLD.run_status = 'post_record_pending' AND NEW.run_status = 'suspended')
            ) THEN
                RAISE EXCEPTION 'run: transition from % to % is not permitted (run %)',
                    OLD.run_status, NEW.run_status, OLD.id;
            END IF;

            -- 保留へ入る場合は、保留種別と保留日時の記録を必須とする。
            -- （pending_note は画面が空欄を許容しているため任意のままとする）
            IF NEW.run_status = 'suspended' THEN
                IF NEW.suspension_type IS NULL OR NEW.suspended_at IS NULL THEN
                    RAISE EXCEPTION 'run: suspending a run requires suspension_type and suspended_at to be recorded (run %)', OLD.id;
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
        RAISE EXCEPTION '068 failed: enforce_run_finalize_lockdown not found';
    END IF;
    IF v_src NOT LIKE '%transition from % to % is not permitted%' THEN
        RAISE EXCEPTION '068 failed: the run_status transition allowlist was not installed';
    END IF;
    IF v_src NOT LIKE '%requires suspension_type and suspended_at to be recorded%' THEN
        RAISE EXCEPTION '068 failed: suspending a run does not require the suspension fields';
    END IF;
    -- 既存の保護が失われていないこと
    IF v_src NOT LIKE '%cannot transition out of finalized state%'
       OR v_src NOT LIKE '%cannot transition out of archived state%'
       OR v_src NOT LIKE '%only the resume operation is permitted%'
    THEN
        RAISE EXCEPTION '068 failed: an existing lockdown branch was lost';
    END IF;

    -- トリガーが run に接続されたままであること
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid
         WHERE NOT t.tgisinternal
           AND c.relname = 'run'
           AND t.tgfoid = 'public.enforce_run_finalize_lockdown'::regproc
    ) THEN
        RAISE EXCEPTION '068 failed: the trigger is no longer attached to public.run';
    END IF;

    RAISE NOTICE '068: run_status transitions are now governed by an explicit allowlist (draft/post_record_pending -> archived is rejected)';
END;
$selfcheck$;
