-- ============================================================================
-- 033_b1_ms1_snapshot_candidate_rls_reproducibility.sql
--
-- 背景（#44 新規DB通し適用の実施中に自ら発見。田島様からのご指摘ではない）:
--   012（audit_event の再現性是正）と全く同型の不備が snapshot・candidate にも
--   存在することが、新規DBへの001→032通し適用を実施して初めて判明した。
--
--   018 は本番DBに存在した "Authenticated users can do everything on
--   snapshots"（Studio作成・別名）のみを DROP し、"snapshot_own_agency" という
--   名前で新規作成していた。本番ではこの名前の衝突がなかったため適用は
--   成功していた。しかし migration 001 は、最初から "snapshot_own_agency"
--   （FOR句なし＝ALL、WITH CHECKなし）という**同名の**ポリシーを作成して
--   いる。このため新規DBへ 001→018 を順に適用すると、018 の
--   CREATE POLICY snapshot_own_agency が「既に存在する」エラーで失敗する
--   （candidateも同様）。012がaudit_eventについて先に対応していたのと
--   同じ構造の見落としである。
--
-- 【本migrationの方針】
--   012と同一の考え方で、018を書き換えず「実際に本番へ適用した内容」として
--   履歴保持する。本033で、001由来・018由来（自分自身の再作成のため）の
--   両方を明示的に DROP POLICY IF EXISTS してから再作成し、新規DB・既存DBの
--   いずれに適用しても最終状態が一致し、再実行してもエラーにならないように
--   する（冪等）。本番DB（既に018適用済み・最終状態は本migrationと同一）に
--   対しても安全に適用できる。
--
-- 【適用後の期待状態】
--   snapshot・candidate とも、ポリシーは own_agency の1件のみ（FOR ALL、
--   USING・WITH CHECK 双方に agency スコープ）。
-- ============================================================================

-- ── snapshot ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "snapshot_own_agency" ON public.snapshot;
DROP POLICY IF EXISTS "Authenticated users can do everything on snapshots" ON public.snapshot;

CREATE POLICY snapshot_own_agency ON public.snapshot
    FOR ALL TO authenticated
    USING (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()))
    WITH CHECK (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()));

-- ── candidate ───────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "candidate_own_agency" ON public.candidate;
DROP POLICY IF EXISTS "Authenticated users can do everything on candidates" ON public.candidate;

CREATE POLICY candidate_own_agency ON public.candidate
    FOR ALL TO authenticated
    USING (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()))
    WITH CHECK (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()));
