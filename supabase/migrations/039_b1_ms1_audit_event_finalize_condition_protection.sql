-- ============================================================================
-- 039_b1_ms1_audit_event_finalize_condition_protection.sql
--
-- 背景（田島様2026-08-01ご指摘Cへの対応）:
--   `authenticated`はaudit_eventへのINSERT権限（`audit_event_insert_own_agency`
--   ポリシー: 自代理店のrun_idであること・operator_idが呼出者自身であること
--   のみを検査）を保持しており、`event_type`自体には一切の制限がない。
--
--   実測の結果、`finalize_run`（030・038）が確定条件として存在確認する
--   `insurer_list_presented`イベントを、確定を行う本人が事前に直接INSERT
--   で偽造できることを確認した（本番で実際に偽造し、直後に削除して復元
--   済み）。これは、確定条件として採用している記録の経路そのものが
--   保護されていない、という7月27日にお伝えいただいた考え方
--   （「検査条件に昇格した記録は、その記録経路の保護も同じ段階の要件と
--   する」）に反する状態だった。
--
--   あわせて、`authenticated`が保持していた不要な`UPDATE`権限
--   （audit_eventにはUPDATEを許可するポリシーが1件も存在しないため
--   実効的には無害だが、019・026・027の横展開スイープと同じ考え方で
--   衛生的に剥奪すべきもの）も確認したため、あわせて剥奪する。
--
-- 【対応方針】
--   確定条件として採用しているevent_typeのうち、既存のSECURITY DEFINER
--   関数が既にINSERT専任経路として存在するもの
--   （run_finalized・consent_comparison_result → finalize_run、
--   recruiter/customer_smartphone_confirmed → confirm_smartphone、
--   property_profile_recorded → save_property_profile、
--   candidate_coverage_status_updated → update_candidate_coverage_status、
--   exclusion_reason_recorded・exclusion_reason_coded → exclude_candidate、
--   redundancy_resolution_recorded → update_snapshot_redundancy_decisions）
--   は、直接INSERTを一切拒否し、当該関数経由のみに限定する。
--
--   `insurer_list_presented`のみ、既存の専任関数が存在しない
--   （run作成時のバッチINSERTの一部として直接書き込まれている）ため、
--   新たに`record_insurer_list_presented(p_run_id)`を新設し、
--   `src/app/run/new/page.tsx`の該当1件をこの関数呼出しへ切り替える
--   （バッチ全体の再設計ではなく、この1イベントのみを切り出す最小限の
--   変更とする。run作成自体・他の監査イベントの記録方式は変更しない）。
--
--   それ以外のevent_type（issue_shared・manual_review_completed・
--   customer_intent_confirmed・recording_mode_selected・
--   meeting_scene_selected・delivery_recorded 等）は、finalize_run等の
--   確定条件として採用されていないため、既存の信頼モデル
--   （agencyスコープ＋operator_id本人性のみ）のまま維持する。
-- ============================================================================

-- ── 1. insurer_list_presented専任関数の新設 ────────────────────────────
CREATE OR REPLACE FUNCTION public.record_insurer_list_presented(
    p_run_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_insurer_list_presented: no active operator for the calling session';
    END IF;

    SELECT agency_id INTO v_run_agency FROM public.run WHERE id = p_run_id;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run does not belong to caller''s agency';
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'insurer_list_presented', v_operator_id, jsonb_build_object('auto_recorded', true));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_insurer_list_presented(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_insurer_list_presented(uuid) TO authenticated;

-- ── 2. 確定条件イベントの直接INSERTを禁止するトリガー ──────────────────
-- current_user='authenticated'（PostgREST直接経路）からの、以下
-- event_typeへの直接INSERTを拒否する。SECURITY DEFINER関数内からの
-- INSERT（current_user=postgres）は対象外。
CREATE OR REPLACE FUNCTION public.enforce_audit_event_protected_types()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
BEGIN
    IF current_user = 'authenticated' AND NEW.event_type IN (
        'run_finalized', 'consent_comparison_result',
        'recruiter_smartphone_confirmed', 'customer_smartphone_confirmed',
        'property_profile_recorded', 'candidate_coverage_status_updated',
        'exclusion_reason_recorded', 'exclusion_reason_coded',
        'redundancy_resolution_recorded', 'insurer_list_presented'
    ) THEN
        RAISE EXCEPTION 'audit_event: event_type "%" can only be recorded via its dedicated function, not by direct insert', NEW.event_type;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_event_protected_types ON public.audit_event;
CREATE TRIGGER trg_audit_event_protected_types
    BEFORE INSERT ON public.audit_event
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_audit_event_protected_types();

-- ── 3. 不要なUPDATE権限の剥奪（衛生。RLSにより実効的には無害） ─────────
REVOKE UPDATE ON TABLE public.audit_event FROM authenticated;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
BEGIN
    IF has_table_privilege('authenticated', 'public.audit_event', 'UPDATE') THEN
        RAISE EXCEPTION '039 verify failed: authenticated still has UPDATE on audit_event';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
         WHERE c.relname = 'audit_event' AND t.tgname = 'trg_audit_event_protected_types' AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION '039 verify failed: trg_audit_event_protected_types missing';
    END IF;
    RAISE NOTICE '039 verify passed: protected event_types locked to their dedicated functions, UPDATE revoked';
END;
$$;
