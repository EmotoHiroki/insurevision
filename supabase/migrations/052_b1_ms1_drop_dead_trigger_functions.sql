-- ============================================================================
-- 052_b1_ms1_drop_dead_trigger_functions.sql
--
-- 背景（田島様2026-08-04ご指摘6・§4(f)注1で従来から報告していた5件）:
--
--   `block_audit_event_delete` / `block_audit_event_update` / `block_delete`
--   / `enforce_candidate_status` / `enforce_run_finalization` の5関数は、
--   いずれも`RETURNS trigger`型でありながらどのテーブルのどのトリガーにも
--   接続されておらず（pg_triggerとの突合で確認）、アプリからの`.rpc(`呼出し
--   も0件（`src/`全文検索で確認）。035以前のトリガー関数の残骸であり、
--   その役割は現在`enforce_run_finalize_lockdown`・
--   `enforce_audit_event_protected_types`・`enforce_parent_run_not_finalized`
--   が担っている。
--
--   `enforce_run_finalization`は`pg_get_functiondef`で中身を確認したところ、
--   `OLD.intention_confirmed_at`・`OLD.final_candidate_id`・
--   `OLD.exception_flag`など現在の`run`テーブルに存在しない列を参照する
--   コードが残っており、誤って再接続されると存在しない列参照で例外が
--   発生し全run更新が失敗する高リスクな死コードだった。
--
--   削除前にpg_depend等で依存関係がないことを確認済み（トリガー接続0件、
--   その他の依存0件）。田島様のご承認により削除する。
-- ============================================================================

DROP FUNCTION IF EXISTS public.block_audit_event_delete();
DROP FUNCTION IF EXISTS public.block_audit_event_update();
DROP FUNCTION IF EXISTS public.block_delete();
DROP FUNCTION IF EXISTS public.enforce_candidate_status();
DROP FUNCTION IF EXISTS public.enforce_run_finalization();
