-- =============================================
-- Phase2-b-1 (b1-MS1): audit_event RLS強化
-- =============================================
-- 田島様 2026-07-19 ご指摘対応、および 2026-07-20 ご指摘（再現性）対応。
--
-- 【背景】
-- audit_event には、これまでに2系統の旧ポリシーが存在し得る:
--   (a) migration 001 で作成される "audit_event_own_agency"
--       … FOR句なし = ALL（SELECT/INSERT/UPDATE/DELETE）。agency単位ではあるが
--         UPDATE/DELETE も許可されるため、監査記録の追記専用化を満たさない。
--   (b) 本番DBに存在していた "Authenticated users can do everything on audit_events"
--       … qual=true。代理店を問わず全operationが許可される。
-- 本番DBは (b) の状態であり、migration履歴（(a)）と乖離していた。
-- 新規DBへ 001〜011 を順に適用した場合は (a) が残るため、旧版の本migrationでは
-- 本番と同一の最終状態にならなかった。
--
-- 【対応方針】
--   1. 既知の旧ポリシー名 (a)(b) と、本migrationが作成する新ポリシー名の
--      すべてを DROP POLICY IF EXISTS で明示的に整理してから再作成する。
--      これにより、新規DB・既存DBのいずれに適用しても最終状態が一致し、
--      本migrationを再実行してもエラーにならない（冪等）。
--   2. SELECT/INSERT を property_profile と同様に
--      run.agency_id = get_my_agency_id() でスコープする。
--   3. UPDATE/DELETE のポリシーは作成しない。RLS有効時、該当コマンドに一致する
--      ポリシーが存在しなければ拒否されるため、監査記録は追記専用となる。
--
-- 影響確認: src/ 全体で audit_event への .update()/.delete() 呼び出しは存在しない
-- （insert/select のみ）ことを確認済み。

ALTER TABLE audit_event ENABLE ROW LEVEL SECURITY;

-- 旧ポリシーの整理（(a) migration 001 由来 / (b) 本番DB由来）
DROP POLICY IF EXISTS "audit_event_own_agency" ON audit_event;
DROP POLICY IF EXISTS "Authenticated users can do everything on audit_events" ON audit_event;

-- 本migrationが作成するポリシー（再実行時の冪等性のため事前に削除）
DROP POLICY IF EXISTS audit_event_select_own_agency ON audit_event;
DROP POLICY IF EXISTS audit_event_insert_own_agency ON audit_event;

CREATE POLICY audit_event_select_own_agency ON audit_event
    FOR SELECT
    USING (
        run_id IN (
            SELECT id FROM run WHERE agency_id = get_my_agency_id()
        )
    );

CREATE POLICY audit_event_insert_own_agency ON audit_event
    FOR INSERT
    WITH CHECK (
        run_id IN (
            SELECT id FROM run WHERE agency_id = get_my_agency_id()
        )
    );

-- UPDATE/DELETE: ポリシーを設けない。RLS有効時、該当コマンドに一致するポリシーが
-- 存在しなければ authenticated ロールからの UPDATE/DELETE はすべて拒否される。
-- 適用後の期待状態: audit_event のポリシーは上記2件（SELECT/INSERT）のみ。
