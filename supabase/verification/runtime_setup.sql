-- ============================================================================
-- runtime_setup.sql
--
-- 実HTTPによる否定系検証（runtime_http_checks.sh）で使用する使い捨てデータを
-- 作成する。田島様2026-08-06ご指摘4「第三者が再実行できる形」への対応。
--
-- 【重要】本番環境では実行しないこと。
--   本スクリプトは検証用データを作成し、検証の過程で run を確定・保留させる。
--   田島様2026-08-04ご指示のとおり、破壊的な検証は分離した検証用プロジェクトの
--   使い捨てデータに対してのみ実施する。
--   実行前に、対象が検証用プロジェクトであることを必ず確認すること。
--
-- 実行方法:
--   psql "<検証用プロジェクトの接続文字列>" -f supabase/verification/runtime_setup.sql
--
-- 作成されるもの（すべて固定UUIDのため再実行しても増殖しない）:
--   agency_config / auth.users / operator / run 3件 / snapshot / audit_event
--   検証用ログイン: rt-check@example.test / RuntimeCheck!2026
--
-- 後始末: supabase/verification/runtime_teardown.sql を実行する。
-- ============================================================================

-- 対象を取り違えないための保険。実業務データがある環境では中断する。
DO $$
DECLARE v_real int;
BEGIN
    SELECT count(*) INTO v_real FROM public.run
     WHERE id NOT IN ('00000000-0000-0000-0000-0000000000f1'::uuid,
                      '00000000-0000-0000-0000-0000000000f2'::uuid,
                      '00000000-0000-0000-0000-0000000000f3'::uuid);
    IF v_real > 0 THEN
        RAISE EXCEPTION
          'runtime_setup: この環境には既存のrunが%件あります。検証用プロジェクトではない可能性が高いため中断します。', v_real;
    END IF;
END;
$$;

-- ── 前回の検証データを先に片付ける ──────────────────────────────────────
-- 【なぜ必要か】
--   runtime_http_checks.sh は検証の過程で RT-01 と RT-03 を確定させる。
--   確定済みのrunは `enforce_run_finalize_lockdown` により
--   「確定状態から他の状態へ戻すUPDATE」が全ロールで拒否されるため、
--   下の INSERT ... ON CONFLICT DO UPDATE で run_status を 'draft' に
--   戻そうとすると、本スクリプト自体が次のエラーで失敗していた。
--     run: cannot transition out of finalized state (run ...)
--   その結果、後始末をせずに検証を2回続けて実行すると、
--   セットアップが失敗しているにもかかわらず古いデータが残ったまま
--   検証が走り、保留系・証跡系の判定が誤って失敗する状態になっていた。
--
--   UPDATEで状態を戻すのではなく、使い捨てデータを削除してから
--   作り直すことで、直前の状態にかかわらず常に同じ初期状態から始める。
--   これにより、後始末を忘れたまま再実行しても結果が変わらない。
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

INSERT INTO public.agency_config (id, agency_id, agency_name)
VALUES ('00000000-0000-0000-0000-0000000000a1',
        '00000000-0000-0000-0000-0000000000a1', '検証用代理店')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change, email_change_token_new,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
VALUES ('00000000-0000-0000-0000-000000000000',
        '00000000-0000-0000-0000-0000000000c1', 'authenticated', 'authenticated',
        'rt-check@example.test',
        extensions.crypt('RuntimeCheck!2026', extensions.gen_salt('bf')),
        now(), now(), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
        '', '', '', '', '', '', '', '')
-- 同一IDの検証用ユーザーが既に存在する場合でも、必ず本スクリプトの
-- メールアドレス・パスワードへ収束させる（DO NOTHING だと古い資格情報が
-- 残り、後続のログインが失敗する）。
ON CONFLICT (id) DO UPDATE
    SET email              = EXCLUDED.email,
        encrypted_password = EXCLUDED.encrypted_password,
        email_confirmed_at = EXCLUDED.email_confirmed_at,
        updated_at         = now(),
        confirmation_token = '', recovery_token = '', email_change = '',
        email_change_token_new = '', email_change_token_current = '',
        phone_change = '', phone_change_token = '', reauthentication_token = '';

INSERT INTO public.operator (id, auth_user_id, agency_id, name, role, is_active)
VALUES ('00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000c1',
        '00000000-0000-0000-0000-0000000000a1', '検証担当', 'admin', true)
ON CONFLICT (id) DO NOTHING;

-- RT01: 確定まで通す正常系＋証跡検証用
-- RT02: 保留（suspended）の書込み拒否検証用
-- RT03: 並行実行（子行書込み × finalize）検証用
INSERT INTO public.run (id, agency_id, operator_id, customer_type, customer_ref,
                        run_type, run_status, customer_decision, meeting_scene,
                        recording_mode, important_matters_delivered)
VALUES
 ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000b1', 'individual', 'RT-01', 'new_contract',
  'draft', 'renewal_no_change', 'pc_tablet', 'realtime', true),
 ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000b1', 'individual', 'RT-02', 'new_contract',
  'draft', 'renewal_no_change', 'pc_tablet', 'realtime', true),
 ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000a1',
  '00000000-0000-0000-0000-0000000000b1', 'individual', 'RT-03', 'new_contract',
  'draft', 'renewal_no_change', 'pc_tablet', 'realtime', true)
ON CONFLICT (id) DO UPDATE
    SET run_status = 'draft', finalized_at = NULL, suspension_type = NULL,
        pending_note = NULL, suspended_at = NULL;

INSERT INTO public.snapshot (run_id, unresolved_items)
SELECT id, '{}' FROM public.run WHERE customer_ref LIKE 'RT-0%'
ON CONFLICT DO NOTHING;

INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
SELECT id, 'insurer_list_presented', '00000000-0000-0000-0000-0000000000b1', '{}'::jsonb
  FROM public.run WHERE customer_ref LIKE 'RT-0%';

-- RT02 は保留状態にしておく
UPDATE public.run
   SET run_status = 'suspended', suspension_type = 'mid_session',
       pending_note = 'runtime check', suspended_at = now()
 WHERE id = '00000000-0000-0000-0000-0000000000f2';

SELECT 'runtime_setup: ready' AS status,
       (SELECT count(*) FROM public.run WHERE customer_ref LIKE 'RT-0%') AS runs;
