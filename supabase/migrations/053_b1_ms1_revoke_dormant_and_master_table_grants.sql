-- ============================================================================
-- 053_b1_ms1_revoke_dormant_and_master_table_grants.sql
--
-- 背景（田島様2026-08-04ご決定事項への対応）:
--
--   「run_participantは当面deny-allのまま維持で結構です。ただし
--   anon・authenticatedへのテーブル権限は剥奪し、休眠テーブルである旨を
--   資料に明記してください。同じ考え方で、マスタ5テーブルに残る
--   anon・authenticatedのINSERT・UPDATE権限も剥奪してください。」
--
--   run_participant: `src/`全文検索で参照0件を確認（完全に休眠している
--   テーブル）。RLSポリシー0件のためすでに実質deny-allだが、
--   GRANT自体（SELECT/INSERT/UPDATE）が残っており、権限の最小化という
--   観点で是正の余地があった。anon・authenticated双方から全権限を剥奪する。
--
--   マスタ5テーブル（coverage_rule_master・flood_zone_master・
--   restriction_reason_master・insurance_category・insurance_line）:
--   いずれも参照専用のマスタデータで、`src/`全文検索でINSERT/UPDATE/
--   DELETE呼出しが0件であることを確認済み。SELECTは引き続き必要
--   （アプリが参照する）ため維持し、INSERT・UPDATEのみ剥奪する。
--
--   あわせて、candidateテーブルの`anon`ロールへのINSERT・UPDATE権限も
--   同じ理由で剥奪する（`authenticated`は051で既にINSERTを剥奪済みで
--   UPDATEも直接付与されていない。anonについては見落としていた残穴）。
-- ============================================================================

-- run_participant: 完全な休眠テーブル。全権限を剥奪する
REVOKE SELECT, INSERT, UPDATE, DELETE ON public.run_participant FROM anon, authenticated;

-- マスタ5テーブル: SELECTは維持、書込み権限のみ剥奪する
REVOKE INSERT, UPDATE, DELETE ON public.coverage_rule_master      FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.flood_zone_master         FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.restriction_reason_master FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.insurance_category        FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.insurance_line            FROM anon, authenticated;

-- candidate: anonの書込み権限を剥奪（authenticatedは051で対応済み）
REVOKE INSERT, UPDATE, DELETE ON public.candidate FROM anon;
