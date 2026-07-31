-- ============================================================================
-- 033_check.sql
--
-- migration 033（snapshot・candidateのRLS再現性是正）の検証。
--
-- 発見の経緯: #44（新規DBへの001→最新の通し適用）を実施中、migration 018が
-- `snapshot_own_agency`・`candidate_own_agency`という名前でポリシーを
-- 新規作成しようとした際、新規DBでは既にmigration 001が同名のポリシー
-- （FOR句なし・WITH CHECKなし）を作成済みのため名前衝突で失敗することを
-- 発見した。本番では該当ポリシーが別名だったため衝突しなかった。012
-- （audit_event向けの同型の是正）と同じ構造の不備。
-- ============================================================================

DO $$
DECLARE
    v_snapshot_count int;
    v_candidate_count int;
BEGIN
    SELECT count(*) INTO v_snapshot_count FROM pg_policies WHERE schemaname='public' AND tablename='snapshot';
    IF v_snapshot_count <> 1 THEN
        RAISE EXCEPTION '033 verify failed: snapshot has % policies, expected 1', v_snapshot_count;
    END IF;

    SELECT count(*) INTO v_candidate_count FROM pg_policies WHERE schemaname='public' AND tablename='candidate';
    IF v_candidate_count <> 1 THEN
        RAISE EXCEPTION '033 verify failed: candidate has % policies, expected 1', v_candidate_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname='public' AND tablename='snapshot' AND policyname='snapshot_own_agency'
           AND cmd='ALL' AND with_check IS NOT NULL
    ) THEN
        RAISE EXCEPTION '033 verify failed: snapshot_own_agency missing, wrong cmd, or missing WITH CHECK';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname='public' AND tablename='candidate' AND policyname='candidate_own_agency'
           AND cmd='ALL' AND with_check IS NOT NULL
    ) THEN
        RAISE EXCEPTION '033 verify failed: candidate_own_agency missing, wrong cmd, or missing WITH CHECK';
    END IF;

    RAISE NOTICE '033 verify passed: snapshot/candidate each have exactly one policy (own_agency, FOR ALL, WITH CHECK present)';
END;
$$;

-- ============================================================================
-- 実測記録（新規Supabaseプロジェクト insurevision-migration-replay-test、
-- 2026-07-31、001→035を通し適用した結果）:
--   033適用前: migrations/018を適用しようとした時点で
--   `ERROR: 42710: policy "snapshot_own_agency" for table "snapshot"
--   already exists` により失敗することを確認した（001が作成した同名
--   ポリシーとの衝突）。033を018の直後に適用したところ、以後の019〜035
--   すべてが正常に適用でき、最終的なポリシー件数・定義は本番と完全に
--   一致することを確認した（本番: snapshot=1件・candidate=1件、
--   いずれもown_agency/ALL/WITH CHECK付き）。
-- ============================================================================
