-- ============================================================================
-- 047_b1_ms1_archived_state_freeze_gap.sql
--
-- 【緊急・046適用直後に自ら発見した穴】
-- 046でfinalized→archived遷移を許可する例外を追加した際、
-- `enforce_run_finalize_lockdown`の「既に確定済みの行は直接書込み禁止」
-- という判定条件が`OLD.run_status = 'finalized'`のみを見ており、
-- **archived状態になった後の行がこの保護対象から完全に外れてしまう**
-- 誤りを作り込んでいた。実機検証で、archived後にauthenticatedが
-- `diagnosis_memo`等の無関係な列を自由に書き換えられてしまうことを
-- 確認した（本来は確定済み同様、凍結された状態であるべき）。
--
-- 【対応】
--   archivedもfinalizedと同様に凍結状態として扱う。archivedからの
--   離脱（別状態への遷移）は誰であっても禁止し、authenticatedによる
--   archived行への直接書込みも一切禁止する。finalized→archivedの
--   一度きりの遷移のみを許可する構造は046のまま維持する。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
    v_new_normalized public.run;
BEGIN
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized'
       AND NEW.run_status IS DISTINCT FROM 'archived'
    THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    -- archivedは終端状態。誰であっても離脱（別状態への遷移）を禁止する
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

        -- archived行への直接書込みも一切禁止（finalizedと同様に凍結）
        IF OLD.run_status = 'archived' THEN
            RAISE EXCEPTION 'run: row is archived, no further direct modification permitted (run %)', OLD.id;
        END IF;

        IF NEW.run_status = 'finalized' THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
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
    END IF;

    RETURN NEW;
END;
$$;

-- run_idを持つ子テーブルの凍結判定も、archived状態を対象に含める
CREATE OR REPLACE FUNCTION public.enforce_parent_run_not_finalized()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
    v_run_status text;
BEGIN
    IF current_user <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    SELECT run_status INTO v_run_status FROM public.run WHERE id = NEW.run_id;
    IF v_run_status IN ('finalized', 'archived') THEN
        RAISE EXCEPTION '%: parent run is %, direct modification no longer permitted (run %)', TG_TABLE_NAME, v_run_status, NEW.run_id;
    END IF;

    RETURN NEW;
END;
$$;
