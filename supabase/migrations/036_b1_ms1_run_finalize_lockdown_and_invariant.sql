-- ============================================================================
-- 036_b1_ms1_run_finalize_lockdown_and_invariant.sql
--
-- 背景（田島様2026-08-01ご指摘Aへの対応）:
--   `run` テーブルへの `authenticated` の table-wide INSERT/UPDATE権限が
--   残っており、`run_update_own_agency` ポリシーは代理店単位で対象行を
--   限定するのみで、列単位の制限がない。実測の結果、同一代理店の
--   active operatorが `run_status='finalized'`・`finalized_at`・
--   `finalized_by`・`pdf_object_key`・`pdf_sha256` を直接PATCHで
--   forge（偽造）でき、`finalize_run`（030）の全Fail-Closed検査を完全に
--   迂回できることを実測で確認した（本番で実際に確定状態を偽造し、
--   ただちに復元済み）。
--
-- 【方針】田島様ご指摘のとおり、個別関数へのガード追加ではなく、
--   「確定状態の判定基準」をDB側で一元的に定義する。
--
--   1. 確定状態の正本（source of truth）を
--      `run_status = 'finalized' <=> finalized_at IS NOT NULL`
--      という不変条件として CHECK 制約で常時強制する。
--      これにより、どの経路であっても片方だけを設定した不整合な状態は
--      物理的に作成できなくなる。
--
--   2. `run` への BEFORE UPDATE トリガーで、以下を絶対規則として強制する。
--        a) `finalized` から他状態への遷移は、呼出者を問わず常に拒否する
--           （確定は不可逆。現状finalize_runにも他の関数にも
--           「un-finalize」する経路は存在しないため、無条件禁止で安全）。
--        b) `current_user = 'authenticated'`（PostgREST経由の直接UPDATE。
--           SECURITY DEFINER関数内からの呼出しは `current_user` が
--           関数所有者=`postgres` に切り替わるため区別できる）の場合、
--           `run_status` を `finalized` へ設定すること、および
--           `finalized_at`・`finalized_by`・`pdf_object_key`・
--           `pdf_sha256`・`export_status` の変更を一切拒否する。
--           これらは `finalize_run` 経由でのみ変更可能となる。
--
--   この設計により、今後 finalize_run 以外にどのような新しい書込み経路
--   （API・RPC・直接操作）が増えても、確定状態を偽造する経路は
--   トリガーレベルで一律に遮断される。
-- ============================================================================

-- ── 1. 確定状態の不変条件（正本の定義） ────────────────────────────────
ALTER TABLE public.run
  ADD CONSTRAINT run_finalized_state_consistency
  CHECK ((run_status = 'finalized') = (finalized_at IS NOT NULL));

-- ── 2. 確定ロック・トリガー ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
BEGIN
    -- (a) 確定済みからの逆遷移は、呼出者を問わず常に拒否する
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized' THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    -- (b) authenticated（直接Data API経由）からの確定関連列の変更を拒否する。
    --     finalize_run はSECURITY DEFINERであり、実行中は current_user が
    --     関数所有者（postgres）に切り替わるため、この判定で区別できる。
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
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_run_finalize_lockdown ON public.run;
CREATE TRIGGER trg_run_finalize_lockdown
    BEFORE UPDATE ON public.run
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_run_finalize_lockdown();

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE v_bad int;
BEGIN
    SELECT count(*) INTO v_bad FROM public.run
     WHERE (run_status = 'finalized') IS DISTINCT FROM (finalized_at IS NOT NULL);
    IF v_bad <> 0 THEN
        RAISE EXCEPTION '036 verify failed: % rows violate the finalized-state invariant', v_bad;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
         WHERE c.relname = 'run' AND t.tgname = 'trg_run_finalize_lockdown' AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION '036 verify failed: trg_run_finalize_lockdown missing';
    END IF;

    RAISE NOTICE '036 verify passed: finalized-state invariant enforced by CHECK constraint, finalize-owned columns locked by trigger';
END;
$$;
