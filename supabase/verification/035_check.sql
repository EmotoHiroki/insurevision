-- ============================================================================
-- 035_check.sql
--
-- migration 035（updated_atトリガーの後方互換追記）の検証。
--
-- 発見の経緯: #44（新規DBへの001→034の通し適用）完走後、最終比較として
-- 本番の関数・トリガー一覧と新規DBのそれを突き合わせたところ、
-- `update_updated_at_column()`関数と、それを使う2件のトリガー
-- （agency_config・agency_rule_overrideのupdated_at自動更新）だけが
-- 新規DBに存在しないことが判明した。008（agency_config等の後方互換
-- テーブル追加）と同種の「本番には存在するがmigrationファイルが無い」
-- ケース。
--
-- あわせて本番に存在する他4関数（block_audit_event_update・
-- block_audit_event_delete・block_delete・enforce_candidate_status・
-- enforce_run_finalization）は、いずれもどのトリガーにも接続されておらず
-- 現時点で無効（既存資料に記載済み・実害なし）であることを再確認した。
-- これらは本migrationの対象外とする。
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
         WHERE c.relname='agency_config' AND t.tgname='trg_agency_config_updated_at' AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION '035 verify failed: trg_agency_config_updated_at missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
         WHERE c.relname='agency_rule_override' AND t.tgname='trg_agency_rule_override_updated_at' AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION '035 verify failed: trg_agency_rule_override_updated_at missing';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='update_updated_at_column' AND pronamespace='public'::regnamespace) THEN
        RAISE EXCEPTION '035 verify failed: update_updated_at_column() missing';
    END IF;

    RAISE NOTICE '035 verify passed: update_updated_at_column() and both agency_config/agency_rule_override triggers present';
END;
$$;

-- 動作確認（実際にUPDATEしてトリガー発火を確認する。本番データを変更する
-- ため、必ずトランザクション内で実施しROLLBACKすること。単独では実行しない）:
--
--   BEGIN;
--   DO $$
--   DECLARE
--       v_before timestamptz;
--       v_after  timestamptz;
--   BEGIN
--       SELECT updated_at INTO v_before FROM public.agency_config LIMIT 1;
--       IF v_before IS NULL THEN
--           RAISE NOTICE '035 trigger behavior check skipped: agency_config has no rows';
--           RETURN;
--       END IF;
--       PERFORM pg_sleep(0.01);
--       UPDATE public.agency_config SET agency_name = agency_name WHERE updated_at = v_before;
--       SELECT updated_at INTO v_after FROM public.agency_config WHERE updated_at > v_before LIMIT 1;
--       IF v_after IS NULL THEN
--           RAISE EXCEPTION '035 verify failed: updated_at did not change after UPDATE (trigger not firing)';
--       END IF;
--       RAISE NOTICE '035 trigger behavior verified: updated_at auto-updated on UPDATE';
--   END;
--   $$;
--   ROLLBACK;
