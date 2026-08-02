-- ============================================================================
-- 045_b1_ms1_plan_selection_function.sql
--
-- 背景（田島様2026-08-01ご指摘H「finalizeが要求する『お客様決定プラン』を
-- 設定するUIが見当たらない」の調査中に発見）:
--
--   「お客様決定プラン」設定UI自体は存在する（`src/app/run/[id]/page.tsx`の
--   「書面・証跡」タブ内、「書面・証跡データを読み込んでください」ボタンを
--   押した後に表示される）。田島様が見つけられなかったのは、finalizeタブ
--   ではなく別タブの奥にあるという配置上の分かりにくさが原因と考えられる
--   （UI導線の問題として別途対応を検討）。
--
--   一方、その保存先である`src/app/api/run/[id]/plan-selection/route.ts`
--   を確認したところ、040以前のsmartphone-confirmルートと全く同型の実装
--   不備が見つかった:
--     1. クライアントから送られた`operatorId`をそのまま`audit_event.
--        operator_id`へ書き込んでいる（呼出者と異なるoperatorIdを偽装
--        できる。監査ログの信頼性が失われる）。
--     2. 対象runが呼出者の所属代理店かどうかの明示的な確認が一切ない
--        （RLSの`run_own_agency`により実際のUPDATE自体は阻止されるが、
--        ルート側はUPDATEが0件で終わった場合でもエラーを検出せず
--        `{success:true}`を返してしまう＝偽の成功応答）。
--     3. `audit_event`へのINSERT失敗（RLS違反等）を一切チェックしていない
--        （エラーを握りつぶして成功応答を返す）。
--     4. `recommendedCandidateId`・`decidedCandidateId`が対象runに属する
--        candidateであることも、`status='active'`であることも検証して
--        いない。外部キー制約は`candidate(id)`のみを見ており、run_idの
--        一致は保証しない。理論上、他のrun（他代理店のrunを含む）の
--        candidate IDを指すダングリングな参照を設定できてしまう。
--     5. is_active=falseのoperatorによる呼出しを拒否するチェックがない。
--
-- 【対応】
--   このエンゲージメント全体で確立してきたパターン（生のテーブル直接
--   UPDATE + 直接audit_event INSERTを、呼出者を自前で特定し全条件を
--   検査するSECURITY DEFINER関数へ置き換える）に統一する。
--   `record_plan_selection(p_run_id, p_recommended_candidate_id,
--   p_decided_candidate_id, p_plan_diff_reason)`を新設し、
--   route.ts側はこの関数を呼ぶだけに変更する（アプリコード変更は
--   別コミットで実施）。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_plan_selection(
    p_run_id                    uuid,
    p_recommended_candidate_id  uuid DEFAULT NULL,
    p_decided_candidate_id      uuid DEFAULT NULL,
    p_plan_diff_reason          text DEFAULT NULL,
    p_set_recommended           boolean DEFAULT false,
    p_set_decided               boolean DEFAULT false,
    p_set_plan_diff_reason      boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id   uuid;
    v_run_agency    uuid;
    v_run_status    text;
    v_old_recommended uuid;
    v_old_decided     uuid;
    v_old_reason      text;
    v_now             timestamptz := now();
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_plan_selection: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status, recommended_candidate_id, decided_candidate_id, plan_diff_reason
      INTO v_run_agency, v_run_status, v_old_recommended, v_old_decided, v_old_reason
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_plan_selection: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_plan_selection: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'record_plan_selection: run not editable';
    END IF;

    IF p_set_recommended AND p_recommended_candidate_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.candidate
             WHERE id = p_recommended_candidate_id AND run_id = p_run_id AND status = 'active'
        ) THEN
            RAISE EXCEPTION 'record_plan_selection: recommended candidate does not belong to this run or is not active';
        END IF;
    END IF;

    IF p_set_decided AND p_decided_candidate_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.candidate
             WHERE id = p_decided_candidate_id AND run_id = p_run_id AND status = 'active'
        ) THEN
            RAISE EXCEPTION 'record_plan_selection: decided candidate does not belong to this run or is not active';
        END IF;
    END IF;

    IF p_set_recommended THEN
        UPDATE public.run SET recommended_candidate_id = p_recommended_candidate_id WHERE id = p_run_id;
        IF p_recommended_candidate_id IS DISTINCT FROM v_old_recommended THEN
            INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
            VALUES (p_run_id, 'recommended_plan_set', v_operator_id, jsonb_build_object('candidate_id', p_recommended_candidate_id));
        END IF;
    END IF;

    IF p_set_decided THEN
        UPDATE public.run SET decided_candidate_id = p_decided_candidate_id WHERE id = p_run_id;
        IF p_decided_candidate_id IS DISTINCT FROM v_old_decided THEN
            INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
            VALUES (p_run_id, 'decided_plan_set', v_operator_id, jsonb_build_object('candidate_id', p_decided_candidate_id));
        END IF;
    END IF;

    IF p_set_plan_diff_reason THEN
        UPDATE public.run
           SET plan_diff_reason = p_plan_diff_reason,
               plan_diff_reason_recorded_at = CASE WHEN p_plan_diff_reason IS NOT NULL THEN v_now ELSE NULL END
         WHERE id = p_run_id;
        IF p_plan_diff_reason IS NOT NULL AND p_plan_diff_reason IS DISTINCT FROM v_old_reason THEN
            INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
            VALUES (p_run_id, 'plan_diff_reason_recorded', v_operator_id,
                    jsonb_build_object('reason', p_plan_diff_reason, 'recorded_at', v_now));
        END IF;
    END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_plan_selection(uuid, uuid, uuid, text, boolean, boolean, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_plan_selection(uuid, uuid, uuid, text, boolean, boolean, boolean) TO authenticated;

-- ── 直接書込み経路の封鎖 ────────────────────────────────────────────────
-- record_plan_selection()を唯一の書込み経路にする。036/043で導入した
-- Freezeロックダウン・トリガーを拡張し、同じ一箇所で管理する。
CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
BEGIN
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized' THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    IF current_user = 'authenticated' THEN
        IF (NEW.run_status = 'finalized' AND OLD.run_status IS DISTINCT FROM 'finalized')
           OR NEW.finalized_at   IS DISTINCT FROM OLD.finalized_at
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

CREATE OR REPLACE FUNCTION public.enforce_audit_event_protected_types()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
BEGIN
    IF current_user = 'authenticated' AND NEW.event_type IN (
        'run_finalized', 'consent_comparison_result',
        'recruiter_smartphone_confirmed', 'customer_smartphone_confirmed',
        'property_profile_recorded', 'candidate_coverage_status_updated',
        'exclusion_reason_recorded', 'exclusion_reason_coded',
        'redundancy_resolution_recorded', 'insurer_list_presented',
        'compare_presented',
        'recommended_plan_set', 'decided_plan_set', 'plan_diff_reason_recorded'
    ) THEN
        RAISE EXCEPTION 'audit_event: event_type "%" can only be recorded via its dedicated function, not by direct insert', NEW.event_type;
    END IF;
    RETURN NEW;
END;
$$;
