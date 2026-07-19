-- =============================================
-- Phase2-b-1 (b1-MS1): audit_event RLS強化
-- =============================================
-- 田島様 2026-07-19 ご指摘対応。
-- 従来の "Authenticated users can do everything on audit_events" (qual=true) は
-- ログイン済みであれば代理店を問わず全operationが許可されており、
-- 複数代理店運用を想定した場合の代理店間データ分離・監査記録保護の要件を満たさない。
--
-- 対応方針:
--   1. SELECT/INSERTを、property_profile と同様に run.agency_id = get_my_agency_id() でスコープする
--   2. UPDATE/DELETEのポリシーは作成しない（アプリコードはinsert/selectのみ使用。
--      監査記録は追記のみとし、更新・削除は authenticated ロールに対して拒否する）
--
-- 影響確認: src/ 全体で audit_event への .update()/.delete() 呼び出しは存在しない
-- （insert/selectのみ）ことを確認済み。

DROP POLICY IF EXISTS "Authenticated users can do everything on audit_events" ON audit_event;

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

-- UPDATE/DELETE: ポリシーを設けない。RLS有効時、該当コマンドに一致するポリィが
-- 存在しなければ authenticated ロールからの UPDATE/DELETE はすべて拒否される。
