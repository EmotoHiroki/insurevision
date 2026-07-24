-- =============================================
-- Phase2-b-1 b1-MS1 是正 第1段階: 代理店分離の基点（operator・一意制約・GRANT・audit_event本人性）
-- =============================================
-- 田島様2026-07-21合意の第1段階。区分B（既存実装の是正・追加費用なし）。
--
-- 【本ファイルの状態】
--   ・田島様2026-07-24ご承認により、本番DB（ytpaklotlgrbslshjggc）へ適用済み（012→013→014の順）。
--   ・適用後、実operatorとしてSELECT件数の無変更（run/audit_event/operator）を確認済み。
--   ・適用前の役割切替による否定系（agency_id付替・他operator_id記録の拒否）は
--     事前にロールバック付きトランザクションで実測済み（別紙証跡参照）。
--
-- 【対象（第1段階）】
--   1. operator のRLS再定義（自行のみ更新・agency_id固定・自agency参照・INSERT/DELETE拒否）
--   2. 一意制約（auth_user_id / email）の再現（新規DBから再現可能にする）
--   3. 対象テーブルの過剰GRANT整理（TRUNCATE/REFERENCES/TRIGGER 等の剥奪）
--   4. audit_event INSERT への operator_id 本人性検査の追加
--
-- 【前提の実測（2026-07-22・読取接続）】
--   ・operator は1行、auth_user_id/email の重複なし。既存の本番DBには一意制約が
--     既に存在するが、migration 001 には無く新規DBから再現できないため本migrationで補う。

-- ---------------------------------------------------------------
-- 1. 一意制約の再現（新規DB向け。本番には既に存在するため IF NOT EXISTS 相当で冪等化）
-- ---------------------------------------------------------------
-- get_my_agency_id() は auth_user_id 一意を前提に決定的に動作するため、一意制約は
-- 代理店判定の健全性に必須。既存重複が無いことを確認済み。
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'operator_auth_user_id_key') THEN
        ALTER TABLE operator ADD CONSTRAINT operator_auth_user_id_key UNIQUE (auth_user_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'operator_email_key') THEN
        ALTER TABLE operator ADD CONSTRAINT operator_email_key UNIQUE (email);
    END IF;
END $$;

-- ---------------------------------------------------------------
-- 2. operator のRLS再定義
-- ---------------------------------------------------------------
ALTER TABLE operator ENABLE ROW LEVEL SECURITY;

-- 旧ポリシーの整理（本番DB由来 / 001由来 / 本migration由来の全てを冪等に削除）
DROP POLICY IF EXISTS "Enable read access for all users" ON operator;
DROP POLICY IF EXISTS "Enable insert for authenticated users" ON operator;
DROP POLICY IF EXISTS "Enable update for owners" ON operator;
DROP POLICY IF EXISTS "operator_self" ON operator;
DROP POLICY IF EXISTS operator_select_own_agency ON operator;
DROP POLICY IF EXISTS operator_update_self ON operator;

-- 参照: 自代理店の担当者のみ（他代理店の担当者情報を見せない）
CREATE POLICY operator_select_own_agency ON operator
    FOR SELECT TO authenticated
    USING (agency_id = get_my_agency_id());

-- 更新: 自分の行のみ。かつ agency_id を変更させない（WITH CHECK に agency_id を明示）
CREATE POLICY operator_update_self ON operator
    FOR UPDATE TO authenticated
    USING (auth_user_id = auth.uid())
    WITH CHECK (
        auth_user_id = auth.uid()
        AND agency_id = get_my_agency_id()
    );

-- INSERT / DELETE: ポリシーを設けない（＝拒否）。
-- 担当者の追加・削除は管理者機能として別途設計し、service_role または
-- 照合付きSECURITY DEFINER関数経由に限定する（本MS1範囲外）。

-- ---------------------------------------------------------------
-- 3. audit_event INSERT への operator_id 本人性検査
-- ---------------------------------------------------------------
-- 対象runのagency確認（012で導入済み）に加え、記録される operator_id が
-- 呼出ユーザー本人（auth.uid() に対応する operator）であることを検査する。
-- （SECURITY DEFINER 経由の finalize_run 等は本ポリシーの影響を受けないため、
--   関数側の照合は第3段階で別途対応する。）
DROP POLICY IF EXISTS audit_event_insert_own_agency ON audit_event;
CREATE POLICY audit_event_insert_own_agency ON audit_event
    FOR INSERT TO authenticated
    WITH CHECK (
        run_id IN (SELECT id FROM run WHERE agency_id = get_my_agency_id())
        AND (
            operator_id IS NULL
            OR operator_id IN (SELECT id FROM operator WHERE auth_user_id = auth.uid())
        )
    );

-- ---------------------------------------------------------------
-- 4. 過剰GRANTの整理（対象テーブル）
-- ---------------------------------------------------------------
-- RLSはTRUNCATEに適用されないため、テーブル権限側でTRUNCATE等を剥奪する。
-- 行レベルの制御はRLSポリシーが担うため、authenticated の SELECT/INSERT/UPDATE/DELETE は
-- 維持する（RLSでスコープされる）。anon には対象テーブルへの書込を許可しない。
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['operator','run','audit_event','property_profile'] LOOP
        EXECUTE format('REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE %I FROM anon, authenticated', t);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON TABLE %I FROM anon', t);
    END LOOP;
END $$;

-- 適用後の期待状態:
--   operator: SELECT(自agency) / UPDATE(自行・agency_id固定) の2ポリシー、INSERT/DELETE拒否
--   audit_event: SELECT(自agency) / INSERT(自agency＋operator_id本人性) の2ポリシー、UPDATE/DELETE拒否
--   対象4テーブル: anon の書込およびTRUNCATE/REFERENCES/TRIGGERを剥奪
