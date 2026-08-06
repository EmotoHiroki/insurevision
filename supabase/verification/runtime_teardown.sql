-- ============================================================================
-- runtime_teardown.sql
--
-- runtime_setup.sql で作成した使い捨てデータをすべて削除する。
-- 検証終了後に必ず実行し、検証環境に残骸を残さないこと。
--
-- 実行方法:
--   psql "<検証用プロジェクトの接続文字列>" -f supabase/verification/runtime_teardown.sql
--
-- 注意: Storage上のオブジェクト（proofs/runs/.../proof.json）は
--   storage.objects への直接DELETEが禁止されているため、Storage API 側で
--   削除する必要がある。runtime_http_checks.sh の最後で削除を試みるが、
--   削除用のRLSポリシーが無い環境では残ることがある。その場合は
--   Supabaseダッシュボードの Storage 画面から proofs バケットの
--   runs/ 配下を削除すること。
-- ============================================================================

DELETE FROM public.run_proof
 WHERE run_id IN (SELECT id FROM public.run WHERE customer_ref LIKE 'RT-0%');

DELETE FROM public.audit_event
 WHERE run_id IN (SELECT id FROM public.run WHERE customer_ref LIKE 'RT-0%');

DELETE FROM public.intent_confirmation
 WHERE run_id IN (SELECT id FROM public.run WHERE customer_ref LIKE 'RT-0%');

DELETE FROM public.snapshot
 WHERE run_id IN (SELECT id FROM public.run WHERE customer_ref LIKE 'RT-0%');

DELETE FROM public.candidate
 WHERE run_id IN (SELECT id FROM public.run WHERE customer_ref LIKE 'RT-0%');

DELETE FROM public.run WHERE customer_ref LIKE 'RT-0%';

DELETE FROM public.operator WHERE id = '00000000-0000-0000-0000-0000000000b1';
DELETE FROM auth.users     WHERE id = '00000000-0000-0000-0000-0000000000c1';
DELETE FROM public.agency_config WHERE id = '00000000-0000-0000-0000-0000000000a1';

SELECT 'runtime_teardown: done' AS status,
       (SELECT count(*) FROM public.run)      AS runs_left,
       (SELECT count(*) FROM public.run_proof) AS proofs_left,
       (SELECT count(*) FROM public.operator)  AS operators_left,
       (SELECT count(*) FROM auth.users)       AS users_left;
