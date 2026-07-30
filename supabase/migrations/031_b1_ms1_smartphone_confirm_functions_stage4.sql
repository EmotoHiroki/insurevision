-- ============================================================================
-- 031_b1_ms1_smartphone_confirm_functions_stage4.sql
--
-- 状態: 本番適用済み
--
-- 背景（第4段階本体）:
--   016（2026-07-27）で smartphone_confirm_token への全テーブル権限を
--   anon・authenticatedから剥奪し、未認証での直接列挙・改ざん（実測で確認済み
--   の脆弱性）を遮断した。この結果、当時の直接テーブルアクセスに依存していた
--   3つの経路（トークン発行・状態確認・確認記録）はすべて機能停止していた。
--
--   本migrationは、これらを呼出者照合付きの関数経由へ作り直し、スマホ確認
--   フローを再稼働させる。
--
--   重要な設計上の前提: このフローは、他のSECURITY DEFINER関数（exclude_
--   candidate等）と異なり、**確認する側（お客様・募集人の手元のスマートフォン）
--   は認証済みセッションを持たない**ことを前提とする。したがって
--   get_smartphone_confirm_status・confirm_smartphone の2関数は、
--   auth.uid()による呼出者照合を行わず、anonからも実行できる設計とする。
--   これは意図的な設計であり、他の関数群の「常にauth.uid()を要求する」
--   方針からの逸脱ではない。安全性は、トークン自体（推測困難なUUID）＋
--   使用済み・期限切れの検査＋関数内でのみ許可された操作、によって担保する。
--   一方、トークンの**発行**（issue_smartphone_confirm_token）は、操作する
--   募集人側の操作であるため、既存の関数群と同じくauth.uid()＋is_active＋
--   agency照合を必須とする。
--
-- 対応した論点:
--   - 田島様2026-07-30ご指摘: issue_smartphone_confirm_token でも
--     operator.is_active を確認すること → 対応済み。
--   - トークン期限の境界条件 → expires_at > now() を有効条件とする（厳密不等号）。
--   - 同一run・roleに複数の有効トークンを許すか → 許さない。新規発行時に、
--     同一run_id・roleの既存の未使用・未期限切れトークンをすべて無効化
--     （expires_atをnow()に更新）する。
--   - 0行更新を成功として扱う既存APIの是正 → confirm_smartphone内で
--     run の UPDATE 後に FOUND を確認し、0行であれば例外を送出する。
--   - audit_eventに生のトークン値を残さない → 本トークン方式では、
--     トークンのid自体が呼出時の秘密情報（bearer相当）であるため、
--     audit_eventのpayloadにはtoken_idを含めない（role・confirmed_atのみ）。
-- ============================================================================

-- ── 1. トークン発行（募集人側の操作。認証必須） ─────────────────────────
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
    IF p_role NOT IN ('recruiter', 'customer') THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: invalid role %', p_role;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: run % not found', p_run_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: run does not belong to caller''s agency';
    END IF;

    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'issue_smartphone_confirm_token: run not editable';
    END IF;

    -- 注: RETURNS TABLEの列名`expires_at`が本関数内で暗黙のPL/pgSQL変数として
    -- スコープに入るため、テーブル列`expires_at`への無修飾参照は全箇所で
    -- 「column reference "expires_at" is ambiguous」になり得る（実測で2箇所
    -- 判明: 下記UPDATEのWHERE句、および当初のINSERT...RETURNING INTO）。
    -- 対策として、テーブル参照には必ずエイリアス修飾（t.expires_at等）を用い、
    -- RETURNING INTOは使わずINSERT後に別途SELECTする方式とした。
    -- 同一run・roleの既存の有効トークンをすべて無効化する（複数の有効トークンを許さない）
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


-- ── 2. トークン状態確認（お客様・募集人の手元。未認証） ─────────────────
-- 既存の GET /api/smartphone-confirm と同一の情報開示方針を踏襲する:
-- トークンが有効（未使用・未期限切れ）な場合のみrun情報を返す。
-- 無効なトークンについてはrun情報を一切返さない（お客様情報の漏えい防止）。
CREATE OR REPLACE FUNCTION public.get_smartphone_confirm_status(
    p_token_id uuid
) RETURNS TABLE (
    is_valid boolean,
    is_used boolean,
    is_expired boolean,
    role text,
    confirmed_at timestamptz,
    run_id uuid,
    customer_ref text,
    customer_name text,
    recruiter_smartphone_confirmed_at timestamptz,
    customer_smartphone_confirmed_at timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_used_at    timestamptz;
    v_expires_at timestamptz;
    v_role       text;
    v_run_id     uuid;
    v_is_used    boolean;
    v_is_expired boolean;
    v_is_valid   boolean;
BEGIN
    SELECT t.used_at, t.expires_at, t.role, t.run_id
      INTO v_used_at, v_expires_at, v_role, v_run_id
      FROM public.smartphone_confirm_token t
     WHERE t.id = p_token_id;

    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'get_smartphone_confirm_status: invalid token';
    END IF;

    v_is_used    := (v_used_at IS NOT NULL);
    v_is_expired := (v_expires_at <= now());
    v_is_valid   := (NOT v_is_used AND NOT v_is_expired);

    IF v_is_valid THEN
        RETURN QUERY
        SELECT v_is_valid, v_is_used, v_is_expired, v_role, v_used_at,
               r.id, r.customer_ref, r.customer_name,
               r.recruiter_smartphone_confirmed_at, r.customer_smartphone_confirmed_at
          FROM public.run r WHERE r.id = v_run_id;
    ELSE
        RETURN QUERY
        SELECT v_is_valid, v_is_used, v_is_expired, v_role, v_used_at,
               NULL::uuid, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz;
    END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_smartphone_confirm_status(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_smartphone_confirm_status(uuid) TO anon, authenticated;


-- ── 3. 確認記録（お客様・募集人の手元。未認証） ─────────────────────────
CREATE OR REPLACE FUNCTION public.confirm_smartphone(
    p_token_id uuid
) RETURNS TABLE (success boolean, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_used_at     timestamptz;
    v_expires_at  timestamptz;
    v_role        text;
    v_run_id      uuid;
    v_run_status  text;
    v_run_operator uuid;
    v_new_status  text;
    v_event_type  text;
BEGIN
    SELECT t.used_at, t.expires_at, t.role, t.run_id
      INTO v_used_at, v_expires_at, v_role, v_run_id
      FROM public.smartphone_confirm_token t
     WHERE t.id = p_token_id;

    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'confirm_smartphone: invalid token';
    END IF;
    IF v_used_at IS NOT NULL THEN
        RAISE EXCEPTION 'confirm_smartphone: token already used';
    END IF;
    IF v_expires_at <= now() THEN
        RAISE EXCEPTION 'confirm_smartphone: token expired';
    END IF;

    SELECT run_status, operator_id INTO v_run_status, v_run_operator
      FROM public.run WHERE id = v_run_id;

    IF v_run_status IS DISTINCT FROM 'draft' THEN
        RAISE EXCEPTION 'confirm_smartphone: run not editable';
    END IF;

    IF v_role = 'recruiter' THEN
        v_new_status := 'recruiter_confirmed';
        v_event_type := 'recruiter_smartphone_confirmed';
        UPDATE public.run
           SET smartphone_conf_status = v_new_status,
               recruiter_smartphone_confirmed_at = now()
         WHERE id = v_run_id;
    ELSE
        v_new_status := 'customer_confirmed';
        v_event_type := 'customer_smartphone_confirmed';
        UPDATE public.run
           SET smartphone_conf_status = v_new_status,
               customer_smartphone_confirmed_at = now()
         WHERE id = v_run_id;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'confirm_smartphone: run % not found during update', v_run_id;
    END IF;

    -- トークンを使用済みにする（同一トークンでの再利用を防ぐ）
    UPDATE public.smartphone_confirm_token SET used_at = now() WHERE id = p_token_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'confirm_smartphone: token % not found during update', p_token_id;
    END IF;

    -- 生のトークン値はpayloadに含めない（role・確認時刻のみ記録）
    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, v_event_type, v_run_operator,
            jsonb_build_object('role', v_role, 'confirmed_at', now(), 'source', 'smartphone_token'));

    RETURN QUERY SELECT true, v_new_status;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.confirm_smartphone(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.confirm_smartphone(uuid) TO anon, authenticated;
