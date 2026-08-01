-- ============================================================================
-- 041_b1_ms1_smartphone_token_hardening.sql
--
-- 背景（田島様2026-08-01ご指摘Dへの対応）:
--   031の3関数について、以下の点を実コードで確認した。
--
--   1. issue_smartphone_confirm_token: `IF p_role NOT IN ('recruiter',
--      'customer')`はNULLを拒否できない（028のp_status是正と同型）。
--      role列はNOT NULL制約があるため、NULLのまま渡した場合は
--      INSERT時にNOT NULL違反で失敗するが、意図した検査エラーではなく
--      分かりにくいDB制約違反として現れる。
--   2. confirm_smartphone: `IF v_role = 'recruiter' THEN ... ELSE ...`は、
--      recruiter以外の値をすべてcustomer側として処理する。role列は
--      CHECK制約で'recruiter'/'customer'の2値に限定されているため
--      現状は実害がないが、明示的なIF/ELSIF/ELSEに是正し、想定外の値が
--      入った場合は例外を送出するFail-Closedな書き方に統一する。
--   3. confirm_smartphone: `v_expires_at <= now()`はNULLの場合に成立せず
--      期限切れとして拒否されない。expires_at列はNOT NULL DEFAULTで
--      あるため現状は実害がないが、同様にFail-Closedな明示検査に是正する。
--   4. 同時実行時の整合性: issue_smartphone_confirm_token・
--      confirm_smartphoneともに、対象行のロックなしにSELECTしてから
--      UPDATEしている。2つの同時呼出しが同一トークンを対象にした場合、
--      いずれも「未使用」の読み取り結果を得てから両方がUPDATEを完了できる
--      構造的なレースコンディションを確認した（confirm_smartphoneで
--      同一トークンが2回「使用成功」と扱われうる）。
--
--   smartphone_conf_status列が募集人確認・顧客確認の両方で同一列を
--   上書きする点（確認順序によって最終的な値がどちらか一方になり、
--   両方確認済みという状態を表現できない）についても確認した。
--   `recruiter_smartphone_confirmed_at`・`customer_smartphone_confirmed_at`
--   の2列は独立して正しく保持されているが、`run.smartphone_conf_status`
--   列単体を見るアプリコード（`src/app/run/[id]/page.tsx`の表示判定・
--   `src/app/run/[id]/print/agency-report/page.tsx`の帳票表示）は、
--   確認順序次第で誤った状態を表示しうる。これは実際に帳票へ影響する
--   実害のある不具合のため、本migrationとあわせてアプリ側も是正する。
-- ============================================================================

-- ── run.smartphone_conf_status に「両方確認済み」の値を追加 ────────────
ALTER TABLE public.run DROP CONSTRAINT IF EXISTS run_smartphone_conf_status_check;
ALTER TABLE public.run ADD CONSTRAINT run_smartphone_conf_status_check
  CHECK (smartphone_conf_status IN (
    'not_required', 'pending', 'recruiter_confirmed', 'customer_confirmed',
    'both_confirmed', 'paper_fallback'
  ));

CREATE OR REPLACE FUNCTION public.issue_smartphone_confirm_token(
    p_run_id uuid,
    p_role   text
) RETURNS TABLE (token_id uuid, expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
    v_new_id      uuid;
    v_new_expires timestamptz;
BEGIN
    IF p_role IS NULL OR p_role NOT IN ('recruiter', 'customer') THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: invalid role %', p_role;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: no active operator for the calling session';
    END IF;

    -- 同時発行を直列化するため、対象runをロックしてから状態を読む
    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id FOR UPDATE;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: run % not found', p_run_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: run does not belong to caller''s agency';
    END IF;

    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: run not editable';
    END IF;

    UPDATE public.smartphone_confirm_token t
       SET expires_at = now()
     WHERE t.run_id = p_run_id AND t.role = p_role
       AND t.used_at IS NULL AND t.expires_at > now();
    v_new_id := gen_random_uuid();
    INSERT INTO public.smartphone_confirm_token (id, run_id, role)
    VALUES (v_new_id, p_run_id, p_role);

    SELECT t.expires_at INTO v_new_expires FROM public.smartphone_confirm_token t WHERE t.id = v_new_id;

    RETURN QUERY SELECT v_new_id, v_new_expires;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.issue_smartphone_confirm_token(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.issue_smartphone_confirm_token(uuid, text) TO authenticated;


CREATE OR REPLACE FUNCTION public.confirm_smartphone(
    p_token_id uuid
) RETURNS TABLE (success boolean, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_used_at              timestamptz;
    v_expires_at           timestamptz;
    v_role                 text;
    v_run_id               uuid;
    v_run_status           text;
    v_run_operator         uuid;
    v_recruiter_confirmed  timestamptz;
    v_customer_confirmed   timestamptz;
    v_new_status           text;
    v_event_type           text;
BEGIN
    -- 同時使用を直列化するため、トークン行をロックしてから状態を読む
    SELECT t.used_at, t.expires_at, t.role, t.run_id
      INTO v_used_at, v_expires_at, v_role, v_run_id
      FROM public.smartphone_confirm_token t
     WHERE t.id = p_token_id
     FOR UPDATE;

    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'confirm_smartphone: invalid token';
    END IF;
    IF v_used_at IS NOT NULL THEN
        RAISE EXCEPTION 'confirm_smartphone: token already used';
    END IF;
    IF v_expires_at IS NULL OR v_expires_at <= now() THEN
        RAISE EXCEPTION 'confirm_smartphone: token expired';
    END IF;

    -- 対象runもロックする（募集人確認・顧客確認の同時実行時の
    -- smartphone_conf_status算出を直列化するため）
    SELECT run_status, operator_id, recruiter_smartphone_confirmed_at, customer_smartphone_confirmed_at
      INTO v_run_status, v_run_operator, v_recruiter_confirmed, v_customer_confirmed
      FROM public.run WHERE id = v_run_id FOR UPDATE;

    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'confirm_smartphone: run not editable';
    END IF;

    IF v_role = 'recruiter' THEN
        v_event_type := 'recruiter_smartphone_confirmed';
        v_new_status := CASE WHEN v_customer_confirmed IS NOT NULL THEN 'both_confirmed' ELSE 'recruiter_confirmed' END;
        UPDATE public.run
           SET smartphone_conf_status = v_new_status,
               recruiter_smartphone_confirmed_at = now()
         WHERE id = v_run_id;
    ELSIF v_role = 'customer' THEN
        v_event_type := 'customer_smartphone_confirmed';
        v_new_status := CASE WHEN v_recruiter_confirmed IS NOT NULL THEN 'both_confirmed' ELSE 'customer_confirmed' END;
        UPDATE public.run
           SET smartphone_conf_status = v_new_status,
               customer_smartphone_confirmed_at = now()
         WHERE id = v_run_id;
    ELSE
        RAISE EXCEPTION 'confirm_smartphone: token has unexpected role %', v_role;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'confirm_smartphone: run % not found during update', v_run_id;
    END IF;

    UPDATE public.smartphone_confirm_token SET used_at = now() WHERE id = p_token_id AND used_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'confirm_smartphone: token % not found during update', p_token_id;
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, v_event_type, v_run_operator,
            jsonb_build_object('role', v_role, 'confirmed_at', now(), 'source', 'smartphone_token'));

    RETURN QUERY SELECT true, v_new_status;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.confirm_smartphone(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.confirm_smartphone(uuid) TO anon, authenticated;


-- ── record_smartphone_manual_confirmation（040）にも同一のboth_confirmed
--    算出を適用する（募集人・顧客どちらの確認が先でも整合させる） ────────
CREATE OR REPLACE FUNCTION public.record_smartphone_manual_confirmation(
    p_run_id uuid,
    p_role   text
) RETURNS TABLE (success boolean, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_operator_id         uuid;
    v_run_agency          uuid;
    v_run_status          text;
    v_recruiter_confirmed timestamptz;
    v_customer_confirmed  timestamptz;
    v_new_status          text;
    v_event_type          text;
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

    SELECT agency_id, run_status, recruiter_smartphone_confirmed_at, customer_smartphone_confirmed_at
      INTO v_run_agency, v_run_status, v_recruiter_confirmed, v_customer_confirmed
      FROM public.run WHERE id = p_run_id FOR UPDATE;
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
        v_event_type := 'recruiter_smartphone_confirmed';
        v_new_status := CASE WHEN v_customer_confirmed IS NOT NULL THEN 'both_confirmed' ELSE 'recruiter_confirmed' END;
        UPDATE public.run
           SET smartphone_conf_status = v_new_status,
               recruiter_smartphone_confirmed_at = now()
         WHERE id = p_run_id;
    ELSE
        v_event_type := 'customer_smartphone_confirmed';
        v_new_status := CASE WHEN v_recruiter_confirmed IS NOT NULL THEN 'both_confirmed' ELSE 'customer_confirmed' END;
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
