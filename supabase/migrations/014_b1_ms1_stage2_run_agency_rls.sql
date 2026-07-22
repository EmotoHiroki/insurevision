-- =============================================
-- Phase2-b-1 b1-MS1 是正 第2段階: run のRLS（代理店分離）
-- =============================================
-- 田島様2026-07-21合意の第2段階。区分B（既存実装の是正・追加費用なし）。
-- 前提: 第1段階（013・operator）適用後であること。operatorが未是正のまま
--       run だけ固めても agency_id 付替で迂回可能なため。
--
-- 【本ファイルの状態】本番へは未適用。第2段階のご確認・ご承認後に適用する。
--
-- 【現状（実測）】run のポリシーは "Authenticated users can do everything on runs"
--   （ALL・qual=true・with_check=true）の1件のみ。ログイン済みなら代理店を問わず
--   全runのSELECT/INSERT/UPDATE/DELETEが可能。migration 001 の run_own_agency は
--   本番DBに存在せず、履歴と乖離。
--
-- 【方針】SELECT/INSERT/UPDATE を自代理店に限定。UPDATE は USING と WITH CHECK の
--   両方を指定し、agency_id の他代理店への付け替えを禁止。DELETE はポリシーを
--   設けず拒否（物理削除はアプリに存在せず、取消は run_status='archived' の論理削除）。

ALTER TABLE run ENABLE ROW LEVEL SECURITY;

-- 旧ポリシーの整理（001由来 / 本番DB由来 / 本migration由来を冪等に削除）
DROP POLICY IF EXISTS "run_own_agency" ON run;
DROP POLICY IF EXISTS "Authenticated users can do everything on runs" ON run;
DROP POLICY IF EXISTS run_select_own_agency ON run;
DROP POLICY IF EXISTS run_insert_own_agency ON run;
DROP POLICY IF EXISTS run_update_own_agency ON run;

CREATE POLICY run_select_own_agency ON run
    FOR SELECT TO authenticated
    USING (agency_id = get_my_agency_id());

CREATE POLICY run_insert_own_agency ON run
    FOR INSERT TO authenticated
    WITH CHECK (agency_id = get_my_agency_id());

CREATE POLICY run_update_own_agency ON run
    FOR UPDATE TO authenticated
    USING (agency_id = get_my_agency_id())        -- 更新前: 自agencyの行のみ
    WITH CHECK (agency_id = get_my_agency_id());   -- 更新後: agency_idの付け替えを禁止

-- DELETE: ポリシーを設けない（＝拒否）。
-- 案件の取消は run_status='archived' による論理削除で実装済み。
-- 将来、法令上の物理削除要請に対応する場合は、権限と証跡を伴う
-- 専用のSECURITY DEFINER関数を別途設ける。

-- 適用後の期待状態:
--   run: SELECT/INSERT/UPDATE の3ポリシー（すべて自agency限定・UPDATEはagency_id固定）、
--        DELETEは拒否。他代理店のrunは参照・更新不可。
