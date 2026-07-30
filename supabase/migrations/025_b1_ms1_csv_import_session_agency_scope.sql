-- ============================================================================
-- 025_b1_ms1_csv_import_session_agency_scope.sql
--
-- 状態: 本番適用済み
--
-- 背景（田島様2026-07-30ご指摘A-1への対応）:
--   publicスキーマの全19ポリシーのうち、csv_import_session_agency_policy の
--   1件だけが get_my_agency_id() を使用していなかった。
--
--     run_id IN (SELECT r.id FROM run r JOIN operator op
--                  ON r.agency_id = op.agency_id
--                 WHERE op.auth_user_id = auth.uid())
--
--   operator.is_active を検査していないため、is_active=false の operator でも
--   本ポリシーの条件を満たす。FOR ALL のため SELECT・INSERT・UPDATE・DELETE の
--   すべてに影響する。019で剥奪したのはTRUNCATE・REFERENCES・MAINTAINのみで
--   あり、この4操作に対する権限（GRANT）は残ったままだった。
--
--   また WITH CHECK が設定されていなかった（qual のみ、with_check は NULL）。
--   INSERT・UPDATE で他agencyのrun_idを指定した場合、USING句はSELECT時にのみ
--   意味を持ち、書込み時の検査が事実上存在しない状態だった。
--
-- 対応:
--   他のagencyスコープテーブル（snapshot・candidate・property_profile等）と
--   同一のパターンへ統一する。get_my_agency_id() は is_active=true を検査する
--   （018で追加済み）ため、追加の是正なしに is_active=false を拒否するように
--   なる。USING・WITH CHECK の両方を設定する。
--
-- 補足（実測・2026-07-30）:
--   csv_import_session は現時点で0件、アプリコード（src/）からの参照も
--   0件であり、本番で使用されていないテーブルである。run_id はNULL許容の
--   列だが、書込み時に run_id が NULL であれば WITH CHECK は NULL（非true）
--   となり拒否される。将来この列にNULL run_idでの挿入を許容する設計が
--   必要になった場合は、別途ポリシーの見直しが必要。
--
-- 自己検査（DOブロック）は、田島様2026-07-28ご指摘4・2026-07-30ご指摘C-4の
-- 方針に従い、本ファイルには含めず supabase/verification/025_check.sql へ
-- 分離した（016・017・024と同一の扱い）。本ファイルは本番で実行したDDL
-- 2文（DROP POLICY・CREATE POLICY）のみで構成する。
-- ============================================================================

DROP POLICY IF EXISTS csv_import_session_agency_policy ON public.csv_import_session;

CREATE POLICY csv_import_session_own_agency ON public.csv_import_session
    FOR ALL TO authenticated
    USING (run_id IN (SELECT id FROM public.run WHERE agency_id = public.get_my_agency_id()))
    WITH CHECK (run_id IN (SELECT id FROM public.run WHERE agency_id = public.get_my_agency_id()));
