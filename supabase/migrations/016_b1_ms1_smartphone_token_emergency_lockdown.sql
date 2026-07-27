-- ============================================================================
-- 016_b1_ms1_smartphone_token_emergency_lockdown.sql
--
-- 目的: smartphone_confirm_token への未認証アクセスを緊急に遮断する。
--
-- 背景:
--   田島様2026-07-25ご指摘9を推論ではなく実測で検証したところ、未認証（anon）の
--   状態で以下が成立することを確認した（トランザクション内・ROLLBACK済み）。
--     - smartphone_confirm_token の全18件が SELECT で読み取れる
--     - 使用済みトークンの used_at を NULL に戻す UPDATE が成立する（rows_updated=1）
--     - expires_at を延長する UPDATE が成立する
--   すなわち、使用済みトークンを未認証で再利用可能な状態に戻せる。
--
-- 本migrationの位置づけ:
--   田島様2026-07-27ご指示により、本件のみ第3〜第5段階の設計承認を待たず先行適用する。
--   「他の指摘と異なり、設計協議の結論に依存せず単独で適用でき、スマホ確認フローは
--   現在すでに外部から成立しない状態のため、業務への影響もない」とのご判断による。
--
-- 本migrationに含めないもの（第4段階・設計承認後）:
--   - get_smartphone_confirm_status / confirm_smartphone_token / issue_smartphone_confirm_token
--     の3関数。これらは設計協議の対象であり、承認前に作成しない。
--   - したがって本migration適用後、スマホ確認フローはDBレベルで完全に停止する。
--     これは意図した状態であり、第4段階完成まで当該フローは外部利用不可として扱う。
--
-- 破壊される既存経路（いずれも意図的）:
--   - /api/run/[id]/smartphone-token        : authenticated からの直接 INSERT
--   - /api/smartphone-confirm (GET/POST)    : anon からの直接 SELECT / UPDATE
--   両ルートとも createServerSupabaseClient()（ANON KEY）を使用するため、
--   anon または authenticated として実行される。service_role は本migrationの
--   REVOKE 対象外のため、管理経路からの操作は従来どおり可能。
-- ============================================================================

-- ── 1. RLS を有効化する ─────────────────────────────────────────────────
-- ポリシーを1件も作成しないため、RLSの評価対象となるロール（anon・authenticated
-- 等、rolbypassrls=false のロール）からは全行が不可視・変更不可となる。
-- 「RLS有効 かつ ポリシー0件」は deny-all を意味する。
ALTER TABLE public.smartphone_confirm_token ENABLE ROW LEVEL SECURITY;

-- ── 2. RLS を所有者にも強制する ────────────────────────────────────────
-- テーブル所有者はデフォルトでRLSを迂回する。将来、所有者ロールで動作する
-- 経路が追加された場合に意図せず迂回されることを防ぐ。
-- （SECURITY DEFINER 関数は定義者権限で動作するため、第4段階の関数群は
--   FORCE 下でも動作するようRLSではなく関数内の照合で認可する設計とする）
ALTER TABLE public.smartphone_confirm_token FORCE ROW LEVEL SECURITY;

-- ── 3. テーブル権限を剥奪する ──────────────────────────────────────────
-- RLSは「行の可視性」を制御するが、テーブル権限（GRANT）は別軸の制御であり、
-- 両方を閉じる必要がある。田島様ご指示のとおり PUBLIC を明示的に含める。
--
-- PUBLIC は擬似ロールであり、PUBLIC への付与は全ロールに効果を持つ。
-- anon・authenticated から個別にREVOKEしても、PUBLIC への付与が残っていれば
-- 権限は残存するため、PUBLIC を先に剥奪する。
REVOKE ALL ON TABLE public.smartphone_confirm_token FROM PUBLIC;
REVOKE ALL ON TABLE public.smartphone_confirm_token FROM anon;
REVOKE ALL ON TABLE public.smartphone_confirm_token FROM authenticated;

-- 注: ALL は SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER の7権限を含む。
--     TRUNCATE の剥奪は本文で個別に検証せず、has_table_privilege と ACL の
--     実出力で確認する（本番データに対する TRUNCATE の実行試験は行わない）。

-- ── 4. 適用結果の自己検証 ──────────────────────────────────────────────
-- 適用トランザクション内で、意図した状態になっていることを検査する。
-- 失敗した場合は例外を送出し、migration 全体をロールバックさせる。
DO $$
DECLARE
    v_rls_enabled  boolean;
    v_rls_forced   boolean;
    v_policy_count integer;
    v_remaining    text;
BEGIN
    SELECT c.relrowsecurity, c.relforcerowsecurity
      INTO v_rls_enabled, v_rls_forced
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = 'smartphone_confirm_token';

    IF v_rls_enabled IS DISTINCT FROM true THEN
        RAISE EXCEPTION '016 self-check failed: RLS is not enabled on smartphone_confirm_token';
    END IF;

    IF v_rls_forced IS DISTINCT FROM true THEN
        RAISE EXCEPTION '016 self-check failed: RLS is not FORCEd on smartphone_confirm_token';
    END IF;

    -- 直接アクセスを許可するポリシーが存在しないこと（田島様ご指示）
    SELECT count(*) INTO v_policy_count
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename  = 'smartphone_confirm_token';

    IF v_policy_count <> 0 THEN
        RAISE EXCEPTION '016 self-check failed: expected 0 policies, found %', v_policy_count;
    END IF;

    -- PUBLIC・anon・authenticated に残存権限がないこと。
    -- has_table_privilege を7権限すべてについて評価する。
    SELECT string_agg(format('%s:%s', g.grantee, g.priv), ', ' ORDER BY g.grantee, g.priv)
      INTO v_remaining
      FROM (
          SELECT r.rolname AS grantee, p.priv
            FROM (VALUES ('public'), ('anon'), ('authenticated')) AS r(rolname)
           CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'),
                              ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) AS p(priv)
           WHERE has_table_privilege(r.rolname, 'public.smartphone_confirm_token', p.priv)
      ) g;

    IF v_remaining IS NOT NULL THEN
        RAISE EXCEPTION '016 self-check failed: privileges remain -> %', v_remaining;
    END IF;

    RAISE NOTICE '016 self-check passed: RLS enabled+forced, 0 policies, no privileges for PUBLIC/anon/authenticated';
END;
$$;
