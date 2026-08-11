-- ============================================================================
-- 076_b1_ms1_deactivate_test_account_operators.sql
--
-- 田島様 判断事項3（本番テスト用アカウント4件の整理）への対応のうち、
-- operator 行の無効化部分。
--
-- 【ご判断の内容】
--   件数を保全 → セッション／リフレッシュトークンの失効・削除 →
--   auth 4件の削除 → 関連する operator は `is_active=false` で保持。
--
-- 【本migrationの位置づけ】
--   認証側（`auth.users`・`auth.sessions`・`auth.refresh_tokens`）の削除は、
--   migration の対象ではないため別途実施済みである（実施記録は完了報告書を参照）。
--     削除前: 認証アカウント4件・セッション71件・リフレッシュトークン74件
--     削除後: いずれも0件
--   本migrationは、田島様2026-08-08ご指摘9の運用
--   「DBのデータ変更は原則として新しいmigrationを経由する」に従い、
--   `public.operator` 側の変更のみを担う。
--
-- 【対象】
--   2026-07-28〜29の二代理店テスト（J-4証跡）で作成した operator 行3件。
--   別紙「seed-user 削除 実施記録」§6.2 の表に対応する。
--
--     65085466-8989-4ea7-bea0-23f8280c20ea  Test Operator B
--     c3906e97-0588-4611-8ad6-6eb78cc4f078  テスト操作者C（同代理店・無効。既に is_active=false）
--     c2123ecb-0a10-4761-81f2-24b64c093744  Test Operator D
--
--   `test-unlinked-no-operator@insurevision-test.local` には operator 行が無いため
--   対象外である（認証アカウントの削除のみで完結する）。
--   seed-user 由来の operator（e4248068-…）は migration 075 で対応済みのため
--   本migrationの対象に含めない。
--
-- 【業務データを消さないこと】
--   operator 行は削除せず、`is_active` を false にするのみである。
--   `run.operator_id`・`run.finalized_by`・`audit_event.operator_id` は
--   いずれも ON DELETE NO ACTION であり、run と監査記録は参照先を保ったまま保持される。
--
-- 既存migrationは編集していない。本ファイルのみを追加する。
-- ============================================================================

DO $apply$
DECLARE
    v_targets uuid[] := ARRAY[
        '65085466-8989-4ea7-bea0-23f8280c20ea'::uuid,
        'c3906e97-0588-4611-8ad6-6eb78cc4f078'::uuid,
        'c2123ecb-0a10-4761-81f2-24b64c093744'::uuid
    ];
    v_present       int;
    v_runs_before   int;
    v_audit_before  int;
    v_runs_after    int;
    v_audit_after   int;
    v_still_active  int;
    v_rows_kept     int;
BEGIN
    SELECT count(*) INTO v_present FROM public.operator WHERE id = ANY(v_targets);

    IF v_present = 0 THEN
        -- 新規DBへの通し適用時など、対象行が存在しない環境では何もしない。
        RAISE NOTICE '076: no test-account operators present in this database; nothing to do';
        RETURN;
    END IF;

    -- 適用前の件数を保全する
    SELECT count(*) INTO v_runs_before  FROM public.run         WHERE operator_id = ANY(v_targets)
                                                                  OR finalized_by = ANY(v_targets);
    SELECT count(*) INTO v_audit_before FROM public.audit_event WHERE operator_id = ANY(v_targets);

    RAISE NOTICE '076 before: operators=% runs_referencing=% audit_referencing=%',
        v_present, v_runs_before, v_audit_before;

    -- operator ID で限定して無効化する（既に false の行はそのまま）
    UPDATE public.operator
       SET is_active = false
     WHERE id = ANY(v_targets)
       AND is_active IS DISTINCT FROM false;

    -- 適用後の確認
    SELECT count(*) INTO v_runs_after  FROM public.run         WHERE operator_id = ANY(v_targets)
                                                                 OR finalized_by = ANY(v_targets);
    SELECT count(*) INTO v_audit_after FROM public.audit_event WHERE operator_id = ANY(v_targets);
    SELECT count(*) INTO v_still_active FROM public.operator   WHERE id = ANY(v_targets) AND is_active;
    SELECT count(*) INTO v_rows_kept    FROM public.operator   WHERE id = ANY(v_targets);

    IF v_runs_after IS DISTINCT FROM v_runs_before THEN
        RAISE EXCEPTION '076 failed: referencing run count changed (% -> %)', v_runs_before, v_runs_after;
    END IF;
    IF v_audit_after IS DISTINCT FROM v_audit_before THEN
        RAISE EXCEPTION '076 failed: referencing audit_event count changed (% -> %)', v_audit_before, v_audit_after;
    END IF;
    IF v_still_active <> 0 THEN
        RAISE EXCEPTION '076 failed: % target operator(s) are still active', v_still_active;
    END IF;
    IF v_rows_kept <> v_present THEN
        RAISE EXCEPTION '076 failed: operator rows must be retained, not deleted (% -> %)', v_present, v_rows_kept;
    END IF;

    RAISE NOTICE '076 after: all % target operators inactive, rows retained, runs=% audit=% (unchanged)',
        v_rows_kept, v_runs_after, v_audit_after;
END;
$apply$;
