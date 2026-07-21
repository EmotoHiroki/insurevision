-- =============================================
-- Phase2-b-1 (b1-MS1): audit_event RLS 再現性の是正
-- =============================================
-- 田島様 2026-07-20 ご指摘（再現性）／2026-07-21 ご承認への対応。
--
-- 【背景】
-- 初版 011 は、本番DBに存在した "Authenticated users can do everything on audit_events"
-- のみを DROP していた。しかし migration 001 が定義するのは別名の
-- "audit_event_own_agency"（FOR句なし＝ALL：SELECT/INSERT/UPDATE/DELETE）である。
-- このため新規DBへ 001→011 を順に適用すると 001由来のALLポリシーが残存し、
-- ポリシーは論理和で評価されるため UPDATE/DELETE が許可されたままとなり、
-- 監査記録の追記専用化が新規DBでは成立しなかった。
--
-- 【本migrationの方針】
-- 初版 011 は「実際に本番へ適用した内容」として履歴保持し、内容は改訂しない。
-- 本 012 で、既知の旧ポリシー名（001由来・本番DB由来）と本migrationが作成する
-- ポリシー名の計4件を DROP POLICY IF EXISTS で明示的に整理してから再作成する。
-- これにより新規DB・既存DBのいずれに適用しても最終状態が一致し、再実行しても
-- エラーにならない（冪等）。既存の本番DB（011適用済み）に対しても安全に適用できる。
--
-- 【適用後の期待状態】
-- audit_event のポリシーは SELECT / INSERT の2件のみ。UPDATE/DELETE 用のポリシーは
-- 存在せず、authenticated ロールからの UPDATE/DELETE は拒否される（追記専用）。
--
-- 影響確認: src/ 全体で audit_event への .update()/.delete() 呼び出しは存在しない
-- （insert/select のみ）ことを確認済み。

ALTER TABLE audit_event ENABLE ROW LEVEL SECURITY;

-- 旧ポリシーの整理（(a) migration 001 由来 / (b) 本番DB由来・初版011で削除済みだが冪等性のため再掲）
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
