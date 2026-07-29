-- ============================================================================
-- 023_b1_ms1_get_my_agency_id_search_path.sql
--
-- 状態: 本番適用済み（execute_sql経由。台帳に別途登録）
--
-- 背景（田島様2026-07-27 23:41ご指摘7への対応）:
--   get_my_agency_id() は008で新規作成された時点から `search_path TO 'public'`
--   のままであり、018でis_active条件を追加した際も変更していなかった。
--   全RLSポリシーの基点となる関数であるため、search_pathを空文字列にし、
--   本体を完全修飾する。
--
-- 検証: 適用前にトランザクション内でドライランし、既存の実operator
--   （auth_user_id 12612143-...）が正しくagency_idを取得できることを
--   SET ROLE経由で確認したうえで本番へ適用した。適用後、実JWT・実Data API
--   経由で以下を再確認済み。
--     - 自代理店の既存operator: run 31件取得（変化なし）
--     - 他代理店operator: 自代理店のsnapshot 1件のみ取得（変化なし）
--     - is_active=false のoperator: run 0件（変化なし）
--     - 未認証（anon）: agency_configアクセスで42501拒否（変化なし）
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_my_agency_id()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT agency_id FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true LIMIT 1;
$function$;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE v_def text;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_def
      FROM pg_proc WHERE proname='get_my_agency_id' AND pronamespace='public'::regnamespace;
    IF v_def NOT LIKE '%SET search_path TO %''''%' THEN
        RAISE EXCEPTION '023 self-check failed: search_path is not empty -> %', v_def;
    END IF;
    IF v_def NOT LIKE '%public.operator%' THEN
        RAISE EXCEPTION '023 self-check failed: operator reference is not fully qualified -> %', v_def;
    END IF;
    RAISE NOTICE '023 self-check passed';
END;
$$;
