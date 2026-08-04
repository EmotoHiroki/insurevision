-- ============================================================================
-- 018_b1_ms1_agency_scope_snapshot_candidate_and_active_operator.sql
--
-- 状態: 本番適用済み（本ファイル作成と同一セッションで適用・実測。詳細は
--       別紙「b1-MS1 第3段階1 追加是正（snapshot/candidate・is_active）」参照）
--
-- 背景（田島様2026-07-27 23:41ご指摘1「snapshot・candidateの外部アクセス条件」の調査結果）:
--
--   1. snapshot・candidate は `FOR ALL TO authenticated USING(true)` であり、
--      agencyの照合が一切ない（migration 014以前の run と同型の欠陥）。
--
--   2. 上記の調査中に、より広範な問題が判明した。全RLSポリシーの基点である
--      `get_my_agency_id()` は operator.is_active を一切確認していない：
--        SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() LIMIT 1;
--      この関数は run・operator・audit_event・property_profile・
--      intent_confirmation・csv_import_session・agency_config・
--      agency_rule_override の agency スコープすべての基点であるため、
--      is_active=false の operator であっても、これらすべてのテーブルで
--      agency スコープのSELECT/INSERT/UPDATEが成立する。
--
--      実測（本番・実JWT・実際のData API経由。2代理店・実運用者アカウントで実施）:
--        is_active=false の実operatorアカウントで、既存の run（31件）・
--        property_profile（4件）・audit_event（100件超）が取得できることを確認した。
--        これは「013・014で是正済み」と報告していたテーブル群が、
--        is_active の観点では是正されていなかったことを意味する。
--
--      すなわち、退職・異動等でis_active=falseにした職員のアカウントが
--      有効なまま残っている限り、その職員は自代理店の全データに
--      引き続きアクセスできる状態だった。
--
-- 対応方針:
--   個別のポリシーをすべて書き換えるのではなく、全ポリシーの基点である
--   get_my_agency_id() 自体に is_active=true の条件を追加する。これにより、
--   この関数を参照する既存の全ポリシー（run・operator・audit_event・
--   property_profile・intent_confirmation・csv_import_session・
--   agency_config・agency_rule_override）が、追加の変更なしに
--   is_active=false のoperatorを一律で締め出す。
--
--   あわせて、snapshot・candidate のポリシーを `USING(true)` から
--   run経由のagencyスコープへ変更する（property_profileと同型）。
--
-- 本migrationに含めないもの（別途・設計協議または恒久是正で対応）:
--   - snapshot.unresolved_items・candidateのstatus/excluded_reason等、
--     確定条件・判定結果を表す列への直接UPDATEの制限。agencyスコープ化により
--     他agencyからの書換えは塞がれるが、同一agency内のactiveなoperatorに
--     よる直接UPDATEは本migration適用後も可能なまま。照合付き書込関数への
--     移行は第3段階の恒久是正で設計する（田島様ご指摘のとおり）。
--   - candidateの残り列（diff_flags, reason_code等）の列単位権限
--   - ビュー・シーケンス経由の迂回経路の確認（別紙で対応）
-- ============================================================================

-- ── 1. get_my_agency_id() に is_active=true の条件を追加 ──────────────────
CREATE OR REPLACE FUNCTION public.get_my_agency_id()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() AND is_active = true LIMIT 1;
$function$;

-- ── 2. snapshot: USING(true) を agency スコープへ変更 ─────────────────────
DROP POLICY IF EXISTS "Authenticated users can do everything on snapshots" ON public.snapshot;

CREATE POLICY snapshot_own_agency ON public.snapshot
    FOR ALL TO authenticated
    USING (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()))
    WITH CHECK (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()));

-- ── 3. candidate: USING(true) を agency スコープへ変更 ─────────────────────
-- candidate.run_id は run(id) を直接参照する外部キー（snapshot経由ではない。
-- candidate_run_id_fkey: FOREIGN KEY (run_id) REFERENCES run(id) ON DELETE CASCADE）。
DROP POLICY IF EXISTS "Authenticated users can do everything on candidates" ON public.candidate;

CREATE POLICY candidate_own_agency ON public.candidate
    FOR ALL TO authenticated
    USING (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()))
    WITH CHECK (run_id IN (SELECT id FROM public.run WHERE agency_id = get_my_agency_id()));

-- ── 4. 自己検査 ────────────────────────────────────────────────────────
DO $$
DECLARE
    v_policy_count integer;
    v_func_def text;
BEGIN
    SELECT count(*) INTO v_policy_count FROM pg_policies
     WHERE schemaname='public' AND tablename='snapshot' AND policyname='snapshot_own_agency';
    IF v_policy_count <> 1 THEN
        RAISE EXCEPTION '018 self-check failed: snapshot_own_agency policy missing';
    END IF;

    SELECT count(*) INTO v_policy_count FROM pg_policies
     WHERE schemaname='public' AND tablename='candidate' AND policyname='candidate_own_agency';
    IF v_policy_count <> 1 THEN
        RAISE EXCEPTION '018 self-check failed: candidate_own_agency policy missing';
    END IF;

    -- 旧USING(true)ポリシーが残っていないこと
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='snapshot' AND qual = 'true') THEN
        RAISE EXCEPTION '018 self-check failed: snapshot still has a USING(true) policy';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='candidate' AND qual = 'true') THEN
        RAISE EXCEPTION '018 self-check failed: candidate still has a USING(true) policy';
    END IF;

    SELECT pg_get_functiondef(oid) INTO v_func_def
      FROM pg_proc WHERE proname='get_my_agency_id' AND pronamespace='public'::regnamespace;
    IF v_func_def NOT LIKE '%is_active = true%' THEN
        RAISE EXCEPTION '018 self-check failed: get_my_agency_id() does not check is_active';
    END IF;

    RAISE NOTICE '018 self-check passed';
END;
$$;
