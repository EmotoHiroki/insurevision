-- ============================================================================
-- 040_b1_ms1_smartphone_manual_confirmation_function.sql
--
-- 背景（田島様2026-08-01ご指摘Dへの対応。および039適用直後に自ら発見した
-- 回帰の是正）:
--   `/api/run/[id]/smartphone-confirm`（トークン方式とは別の、募集人が
--   画面から「確認済みとして記録」を行う既存の経路）は、リクエスト
--   ボディで受け取った`operatorId`をそのまま`audit_event.operator_id`へ
--   書き込んでいた。田島様がこの点を実機確認とあわせてご指摘された。
--
--   調査の結果、`audit_event_insert_own_agency`ポリシー（012・013）の
--   WITH CHECKが`operator_id IS NULL OR operator_id IN (SELECT id FROM
--   operator WHERE auth_user_id = auth.uid())`であるため、他operatorへの
--   なりすましはRLSにより既に拒否される状態だった（030のfinalize_run
--   是正時に、同種の2件のconsent系insertについて同じ理由で対象外とした
--   判断と同一）。ただし、これはコードの意図した設計ではなくRLSに
--   間接的に依存した状態であり、田島様の「クライアント供給の値を
--   信用する構造」というご指摘自体は正しい。
--
--   さらに、039（audit_event記録経路保護）を適用した直後、この既存
--   ルートが直接INSERTしていた`recruiter_smartphone_confirmed`・
--   `customer_smartphone_confirmed`が、039の保護対象event_typeに
--   含まれていたため、本ルートが本番で機能しなくなる回帰を自ら発見した
--   （実測: 同一のINSERTを再現し、039のトリガーにより拒否されることを
--   確認）。039適用と同一のセッション内で発見・是正する。
--
-- 【対応】
--   confirm_smartphone（031）と同一のパターンで、`auth.uid()`から
--   呼出者のoperatorを解決し、agency照合・is_active確認・run確定後
--   Freezeを行うSECURITY DEFINER関数を新設する。トークン方式との違いは、
--   本関数は認証済み募集人自身が呼び出す経路であるため、
--   `smartphone_confirm_token`を介さない。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_smartphone_manual_confirmation(
    p_run_id uuid,
    p_role   text
) RETURNS TABLE (success boolean, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
    v_new_status  text;
    v_event_type  text;
BEGIN
    IF p_role IS NULL OR p_role NOT IN ('recruiter', 'customer') THEN
        RAISE EXCEPTION 'record_smartphone_manual_confirmation: invalid role %', p_role;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_smartphone_manual_confirmation: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_smartphone_manual_confirmation: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_smartphone_manual_confirmation: run does not belong to caller''s agency';
    END IF;
    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'record_smartphone_manual_confirmation: run not editable';
    END IF;

    IF p_role = 'recruiter' THEN
        v_new_status := 'recruiter_confirmed';
        v_event_type := 'recruiter_smartphone_confirmed';
        UPDATE public.run
           SET smartphone_conf_status = v_new_status,
               recruiter_smartphone_confirmed_at = now()
         WHERE id = p_run_id;
    ELSE
        v_new_status := 'customer_confirmed';
        v_event_type := 'customer_smartphone_confirmed';
        UPDATE public.run
           SET smartphone_conf_status = v_new_status,
               customer_smartphone_confirmed_at = now()
         WHERE id = p_run_id;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'record_smartphone_manual_confirmation: run % not found during update', p_run_id;
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, v_event_type, v_operator_id,
            jsonb_build_object('role', p_role, 'confirmed_at', now(), 'source', 'manual'));

    RETURN QUERY SELECT true, v_new_status;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_smartphone_manual_confirmation(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.record_smartphone_manual_confirmation(uuid, text) TO authenticated;
