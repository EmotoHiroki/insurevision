-- ============================================================================
-- 035_b1_ms1_updated_at_trigger_backfill.sql
--
-- 背景（#44 新規DB通し適用の完走後、最終比較で自ら発見。008と同種の
-- 「本番には存在するがmigrationファイルが無い」ケース）:
--   本番には `update_updated_at_column()` 関数と、それを使う2件のトリガー
--   （`agency_config`・`agency_rule_override` の `updated_at` 自動更新）が
--   実際に有効な状態で存在するが、いずれもどのmigrationファイルにも
--   定義がなかった。新規DBへ001→034を通し適用した結果、この2関数・
--   2トリガーだけが本番と一致しないことを確認した。
--
--   あわせて本番には他に4関数（`block_audit_event_update`・
--   `block_audit_event_delete`・`block_delete`・`enforce_candidate_status`・
--   `enforce_run_finalization`）が存在するが、いずれもどのトリガーにも
--   接続されておらず現時点で無効（既存資料
--   `b1-MS1_第3段階_finalize_run設計案.md`・`b1-MS1_対応区分_段階別計画.md`
--   に記載済み）。実害がないため、本migrationでは対象外とする。
--
-- 対応: 008（agency_config等の後方互換テーブル追加）と同じ考え方で、
--   実際に稼働している2トリガー分のみを新規DBでも再現できるよう追記する。
--   すべて冪等（CREATE OR REPLACE FUNCTION・DROP TRIGGER IF EXISTS）。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_agency_config_updated_at ON public.agency_config;
CREATE TRIGGER trg_agency_config_updated_at
    BEFORE UPDATE ON public.agency_config
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS trg_agency_rule_override_updated_at ON public.agency_rule_override;
CREATE TRIGGER trg_agency_rule_override_updated_at
    BEFORE UPDATE ON public.agency_rule_override
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
