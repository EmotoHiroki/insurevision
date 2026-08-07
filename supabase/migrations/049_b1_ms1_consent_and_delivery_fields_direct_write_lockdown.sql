-- ============================================================================
-- 049_b1_ms1_consent_and_delivery_fields_direct_write_lockdown.sql
--
-- 背景（048の実装レビュー中に発見した新規の穴。田島様への報告なしで
-- 発見・是正）:
--
--   048で `record_electronic_consent` / `record_paper_confirmation` /
--   `record_important_matters_delivery` の3関数を新設し、APIルートを
--   これらの関数経由に変更した。しかし、043が `compare_presented_at` や
--   スマホ確認3列に対して行った「専任関数を経由しない直接UPDATEを
--   トリガーで拒否する」という保護を、048では**新設した3関数が扱う列に
--   対して行っていなかった**。
--
--   実測で確認した実際の穴:
--     PATCH /rest/v1/run?id=eq.<run_id>
--     { "electronic_consent_status": "agreed" }
--     → HTTP 204（成功）
--
--   同代理店のauthenticatedユーザーであれば、`record_electronic_consent`等の
--   RPCを経由せず、PostgRESTへの直接PATCHで以下がすべて素通りする。
--     - status/methodの許容値検査
--     - run_statusが'draft'であることの検査
--     - audit_eventへの記録（証跡が残らない）
--     - electronic_consent_operator_idへの任意の値の書込み
--       （他operatorへのなりすましがRLSでのみ防がれ、関数のis_active検査を
--       経由しない）
--
--   これは043で確立した「専任関数を経由しない直接書込みをトリガーで
--   拒否する」というパターンを、048の対象列に適用し忘れたものである。
--   是正の対象は広げたが、是正手段そのものを一部の列にしか
--   適用していなかったという、同型の不備にあたる。
--
-- 【対応】
--   `enforce_run_finalize_lockdown` を拡張し、043・046・047と同じ
--   パターンで、以下の列群への`authenticated`による直接UPDATEを拒否する。
--     - electronic_consent_status / _method / _confirmed_at / _operator_id
--     - paper_confirmation_status / _completed_at
--     - important_matters_delivered / _at / _delivery_method
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

        -- 049で追加: 048が新設した3関数が扱う列群
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
$$;
