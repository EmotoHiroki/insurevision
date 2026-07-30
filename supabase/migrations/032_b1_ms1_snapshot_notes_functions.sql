-- ============================================================================
-- 032_b1_ms1_snapshot_notes_functions.sql
--
-- 状態: 本番適用済み
--
-- 背景（#40の横展開調査中に自ら発見。田島様からのご指摘ではない）:
--   `src/app/run/[id]/page.tsx` は現在も `snapshot` テーブルの
--   `redundancy_decisions`・`resolution_memo` を直接 `.update()` している
--   （重複補償の判断保存・課題解消メモの保存・重複項目の削除、計3箇所）。
--   ところが実測の結果、`authenticated` は `snapshot` への UPDATE 権限を
--   一切保持していない（INSERT・SELECTのみ）ことが判明した。つまり
--   この3つの保存操作は、本番で常に `permission denied` により失敗して
--   いる状態だった（権限剥奪がいつの時点で生じたかは、019〜022の一連の
--   ロックダウンmigrationの過程と推測されるが、いずれのmigrationにも
--   snapshotのUPDATEを明示的に対象とした記述がなく、断定はできない）。
--
--   あわせて、`anon` が `snapshot` への INSERT・UPDATE 権限を保持したままに
--   なっていることも判明した。ただし `snapshot_own_agency` ポリシーは
--   `authenticated` のみを対象（`roles={authenticated}`）としており、
--   RLSが有効・FORCE状態であるため、ポリシーが1件も適用されない`anon`は
--   実効的に0件（読取・書込みとも不可）となる。実害はないが、019/026/027の
--   RLS対象外権限の横展開スイープと同じ考え方で、不要な権限として剥奪する。
--
-- 【対応方針】
--   candidate向けの2関数（024・028で確立済み）・finalize_run（030）・
--   save_property_profile（015）と同一のSECURITY DEFINERパターンを踏襲する。
--   `redundancy_decisions`・`resolution_memo` それぞれについて、現在の
--   アプリの呼出し単位（1回のupdateにつき1フィールドのみ）に合わせて
--   個別の関数とする（NULL＝更新しない、という曖昧さを持ち込まない）。
--
--   確定後の凍結については、page.tsx側の `isEditable` が
--   `run_status IN ('draft','post_record_pending')` を既に条件としている
--   （UIは既にこの2状態でのみ編集可能としていた）。関数側でも同一の条件を
--   検査し、UI側のガードをRPC直接呼出しで迂回できないようにする
--   （candidate関数群・finalize_runと同じ「確定後は変更不可」という
--   一貫した設計に合わせる）。
--
-- 【#40で田島様のご判断が必要な事項について】
--   本migrationは、あくまで「現在壊れている書込み経路の復旧」および
--   「既存のUI側の凍結条件をDB側でも保証する」という技術的に一貫した
--   対応であり、業務判断を要する事項ではないと判断し対応した。
--   一方、exclude_candidateの理由コード必須化（Fail-Closed化。028で
--   対応外とした第4の未決定事項）は、純粋な業務判断であるため、本
--   migrationでは対応しない。別紙にて田島様のご判断を仰ぐ。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_snapshot_redundancy_decisions(
    p_snapshot_id uuid,
    p_redundancy_decisions jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_agency_id  uuid;
    v_run_id     uuid;
    v_run_agency uuid;
    v_run_status text;
BEGIN
    SELECT agency_id INTO v_agency_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_agency_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: no active operator for the calling session';
    END IF;

    SELECT s.run_id INTO v_run_id FROM public.snapshot s WHERE s.id = p_snapshot_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: snapshot not found';
    END IF;

    SELECT r.agency_id, r.run_status INTO v_run_agency, v_run_status
      FROM public.run r WHERE r.id = v_run_id;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'update_snapshot_redundancy_decisions: run not editable';
    END IF;

    UPDATE public.snapshot s
       SET redundancy_decisions = p_redundancy_decisions
     WHERE s.id = p_snapshot_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.update_snapshot_redundancy_decisions(uuid, jsonb) TO authenticated;


CREATE OR REPLACE FUNCTION public.update_snapshot_resolution_memo(
    p_snapshot_id uuid,
    p_resolution_memo text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $$
DECLARE
    v_agency_id  uuid;
    v_run_id     uuid;
    v_run_agency uuid;
    v_run_status text;
BEGIN
    SELECT agency_id INTO v_agency_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_agency_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: no active operator for the calling session';
    END IF;

    SELECT s.run_id INTO v_run_id FROM public.snapshot s WHERE s.id = p_snapshot_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: snapshot not found';
    END IF;

    SELECT r.agency_id, r.run_status INTO v_run_agency, v_run_status
      FROM public.run r WHERE r.id = v_run_id;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'update_snapshot_resolution_memo: run not editable';
    END IF;

    UPDATE public.snapshot s
       SET resolution_memo = p_resolution_memo
     WHERE s.id = p_snapshot_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.update_snapshot_resolution_memo(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.update_snapshot_resolution_memo(uuid, text) TO authenticated;

-- 不要な直接権限の剥奪（RLSにより実効的に無害だったが、019/026/027の
-- 横展開スイープと同じ考え方で衛生的に剥奪する）
REVOKE INSERT, UPDATE ON TABLE public.snapshot FROM anon;
