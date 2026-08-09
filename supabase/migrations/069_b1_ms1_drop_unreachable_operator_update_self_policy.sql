-- ============================================================================
-- 069_b1_ms1_drop_unreachable_operator_update_self_policy.sql
--
-- 田島様2026-08-08ご指摘8への対応。
--
-- 【ご指示】
--   「operator_update_self … 使用経路がないことを再確認したうえで、
--     既存migrationを編集せず、新しいmigrationで削除してください」
--
-- 【削除前の再確認（2026-08-09、本番で実測）】
--   1. ポリシーの現状
--        policyname : operator_update_self
--        table      : public.operator
--        roles      : {authenticated}
--        cmd        : UPDATE
--        qual       : (auth_user_id = auth.uid())
--        with_check : ((auth_user_id = auth.uid()) AND (agency_id = get_my_agency_id()))
--
--   2. `authenticated` が `public.operator` に対して持つテーブル権限
--        SELECT のみ（UPDATE は migration 059 の許可リスト化で剥奪済み）
--
--   3. アプリからの `operator` に対する UPDATE 呼出し
--        0件（`src/` 全体を確認）
--
--   RLSポリシーは、対象ロールが当該操作のテーブル権限を持っている場合にのみ
--   評価される。`authenticated` は `operator` への UPDATE 権限を持たないため、
--   本ポリシーが評価される経路は存在しない。すなわち死んだ定義である。
--
-- 【本migrationで行うこと】
--   評価される機会の無い UPDATE ポリシーを削除する。
--   テーブル権限は変更しない（SELECT のみのまま）。
--
--   なお `operator` は RLS 有効・強制のままであり、
--   本削除により `authenticated` の到達範囲が広がることはない。
--   むしろ「権限が無いので評価されないが定義だけは残っている」という
--   紛らわしい状態を解消するものである。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

DROP POLICY IF EXISTS operator_update_self ON public.operator;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $selfcheck$
DECLARE
    v_cnt  int;
    v_priv text;
BEGIN
    -- 1. 当該ポリシーが存在しないこと
    SELECT count(*) INTO v_cnt
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename  = 'operator'
       AND policyname = 'operator_update_self';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '069 failed: operator_update_self still exists';
    END IF;

    -- 2. operator へ UPDATE 系のポリシーが残っていないこと
    SELECT count(*) INTO v_cnt
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename  = 'operator'
       AND cmd IN ('UPDATE', 'ALL');
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '069 failed: an UPDATE-capable policy remains on public.operator (count=%)', v_cnt;
    END IF;

    -- 3. authenticated のテーブル権限が SELECT のみのまま変わっていないこと
    SELECT coalesce(string_agg(privilege_type, ',' ORDER BY privilege_type), '(none)')
      INTO v_priv
      FROM information_schema.role_table_grants
     WHERE table_schema = 'public'
       AND table_name   = 'operator'
       AND grantee      = 'authenticated';
    IF v_priv IS DISTINCT FROM 'SELECT' THEN
        RAISE EXCEPTION '069 failed: authenticated privileges on public.operator are % (expected SELECT only)', v_priv;
    END IF;

    -- 4. RLS が有効・強制のままであること
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname = 'operator'
           AND c.relrowsecurity AND c.relforcerowsecurity
    ) THEN
        RAISE EXCEPTION '069 failed: RLS is no longer enabled and forced on public.operator';
    END IF;

    RAISE NOTICE '069: the unreachable operator_update_self policy has been removed (authenticated retains SELECT only; RLS remains enabled and forced)';
END;
$selfcheck$;
