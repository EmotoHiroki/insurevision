-- ============================================================================
-- 050_058_check.sql
--
-- migration 050〜058 の適用結果を検証する。
--
-- 田島様2026-08-06ご指摘4への対応。同梱の検証SQLは従来 015〜035 を対象と
-- しており、050〜058 を再検証するものが無かった。本ファイルは、第三者が
-- そのまま再実行して合否を判定できる形にしてある。
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/050_058_check.sql
--   または Supabase SQL Editor に全文を貼り付けて実行
--
-- 判定:
--   すべて合格の場合のみ最後に「050_058_check: ALL CHECKS PASSED」を出力する。
--   1件でも不合格があれば、その時点で EXCEPTION を送出して停止する。
--
-- 注意:
--   本スクリプトは読み取りのみで、データを一切変更しない。
--   接続情報・トークン等の秘密情報は含まない。
-- ============================================================================

DO $$
DECLARE
    v_cnt   int;
    v_txt   text;
    v_bool  boolean;
BEGIN
    -- ── 050: run への直接INSERT封鎖 ─────────────────────────────────────
    SELECT count(*) INTO v_cnt
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relname = 'run' AND t.tgname = 'trg_run_finalize_lockdown'
       AND NOT t.tgisinternal;
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '050 failed: trg_run_finalize_lockdown missing on run';
    END IF;

    SELECT prosrc INTO v_txt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'enforce_run_finalize_lockdown';
    IF v_txt NOT LIKE '%new rows must be created with run_status%' THEN
        RAISE EXCEPTION '050 failed: INSERT lockdown (draft only) not present';
    END IF;
    IF v_txt NOT LIKE '%finalize-owned fields cannot be set on insert%' THEN
        RAISE EXCEPTION '050 failed: finalize-owned column guard on INSERT not present';
    END IF;

    -- ── 051: add_candidate の新設と candidate 直接INSERTの剥奪 ──────────
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'add_candidate';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '051 failed: add_candidate() not found';
    END IF;

    SELECT count(*) INTO v_cnt FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND table_name = 'candidate'
       AND grantee IN ('anon', 'authenticated') AND privilege_type = 'INSERT';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '051 failed: candidate INSERT still granted to anon/authenticated (% grants)', v_cnt;
    END IF;

    -- ── 052: 未参照トリガー関数5件の削除 ───────────────────────────────
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('block_audit_event_delete', 'block_audit_event_update',
                       'block_delete', 'enforce_candidate_status', 'enforce_run_finalization');
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '052 failed: % dead trigger function(s) still present', v_cnt;
    END IF;

    -- ── 053: master系・run_participant の書込み権限剥奪 ─────────────────
    SELECT count(*) INTO v_cnt FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND grantee IN ('anon', 'authenticated')
       AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
       AND table_name LIKE '%master%';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '053 failed: master tables still writable by anon/authenticated (% grants)', v_cnt;
    END IF;

    SELECT count(*) INTO v_cnt FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND table_name = 'run_participant'
       AND grantee IN ('anon', 'authenticated');
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '053 failed: run_participant still granted to anon/authenticated (% grants)', v_cnt;
    END IF;

    -- ── 054: proofs バケットと Storage ポリシー ─────────────────────────
    SELECT count(*) INTO v_cnt FROM storage.buckets WHERE id = 'proofs';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '054 failed: storage bucket "proofs" not found';
    END IF;

    SELECT count(*) INTO v_cnt FROM pg_policies
     WHERE schemaname = 'storage' AND tablename = 'objects'
       AND policyname IN ('proofs_insert_own_agency', 'proofs_update_own_agency', 'proofs_select_own_agency');
    IF v_cnt <> 3 THEN
        RAISE EXCEPTION '054 failed: expected 3 proofs storage policies, found %', v_cnt;
    END IF;

    -- ── 055: 子テーブル共通トリガーの行ロックと post_record_pending 整合 ─
    SELECT prosrc INTO v_txt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'enforce_parent_run_not_finalized';
    IF v_txt NOT LIKE '%FOR UPDATE%' THEN
        RAISE EXCEPTION '055 failed: enforce_parent_run_not_finalized does not lock the parent run row';
    END IF;

    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('record_paper_confirmation', 'record_electronic_consent',
                       'record_important_matters_delivery')
       AND prosrc LIKE '%post_record_pending%';
    IF v_cnt <> 3 THEN
        RAISE EXCEPTION '055 failed: expected 3 consent functions accepting post_record_pending, found %', v_cnt;
    END IF;

    -- ── 056: 状態判定の許可リスト統一 / run_proof の deny-all ───────────
    -- run_status を参照する関数のうち、旧来の拒否リスト方式
    -- （finalized/archived のみ拒否）が残っていないこと
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND prosrc ILIKE '%run_status%'
       AND prosrc LIKE '%IN (''finalized'', ''archived'')%';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '056 failed: % function(s) still use the deny-list form', v_cnt;
    END IF;

    SELECT count(*) INTO v_cnt FROM information_schema.tables
     WHERE table_schema = 'public' AND table_name = 'run_proof';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '056 failed: run_proof table not found';
    END IF;

    SELECT relrowsecurity AND relforcerowsecurity INTO v_bool
      FROM pg_class WHERE relname = 'run_proof' AND relnamespace = 'public'::regnamespace;
    IF NOT coalesce(v_bool, false) THEN
        RAISE EXCEPTION '056 failed: run_proof RLS is not enabled+forced';
    END IF;

    SELECT count(*) INTO v_cnt FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'run_proof';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '056 failed: run_proof must have 0 policies (deny-all), found %', v_cnt;
    END IF;

    SELECT count(*) INTO v_cnt FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND table_name = 'run_proof'
       AND grantee IN ('anon', 'authenticated', 'PUBLIC');
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '056 failed: run_proof still granted to anon/authenticated/PUBLIC (% grants)', v_cnt;
    END IF;

    -- ── 057: 証跡本文のサーバー側生成 / 確定後のStorage凍結 / fail-closed ─
    -- 呼出し元が本文を渡す旧シグネチャが残っていないこと
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'save_run_proof'
       AND pg_get_function_identity_arguments(oid) LIKE '%text%';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '057 failed: save_run_proof still accepts a caller-supplied text payload';
    END IF;

    -- Storage の INSERT/UPDATE ポリシーが run_status を検査していること
    SELECT count(*) INTO v_cnt FROM pg_policies
     WHERE schemaname = 'storage' AND tablename = 'objects'
       AND policyname IN ('proofs_insert_own_agency', 'proofs_update_own_agency')
       AND coalesce(qual, '') || coalesce(with_check, '') LIKE '%run_status%';
    IF v_cnt <> 2 THEN
        RAISE EXCEPTION '057 failed: proofs insert/update policies do not check run_status (found %)', v_cnt;
    END IF;

    SELECT prosrc INTO v_txt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'finalize_run';
    IF v_txt NOT LIKE '%usable eTag%' THEN
        RAISE EXCEPTION '057 failed: finalize_run does not fail closed when eTag is unusable';
    END IF;

    -- ── 058: 確定時の本文再構築 / Storage行ロック / 同意値の一元化 ───────
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND proname = 'build_run_proof_payload';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '058 failed: build_run_proof_payload() not found';
    END IF;

    IF has_function_privilege('authenticated',
        (SELECT oid FROM pg_proc WHERE pronamespace='public'::regnamespace
          AND proname='build_run_proof_payload'), 'EXECUTE') THEN
        RAISE EXCEPTION '058 failed: build_run_proof_payload must not be executable by authenticated';
    END IF;

    SELECT count(*) INTO v_cnt FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relname = 'objects' AND c.relnamespace = 'storage'::regnamespace
       AND t.tgname = 'trg_proof_object_immutable' AND NOT t.tgisinternal;
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '058 failed: trg_proof_object_immutable missing on storage.objects';
    END IF;

    IF v_txt NOT LIKE '%FOR UPDATE%' THEN
        RAISE EXCEPTION '058 failed: finalize_run does not lock the storage object row';
    END IF;
    IF v_txt NOT LIKE '%the run has changed since the proof was registered%' THEN
        RAISE EXCEPTION '058 failed: finalize_run does not rebuild and compare the proof payload';
    END IF;
    IF v_txt NOT LIKE '%consent flags differ from those recorded in the proof%' THEN
        RAISE EXCEPTION '058 failed: finalize_run does not enforce consent flag consistency';
    END IF;

    SELECT count(*) INTO v_cnt FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'run_proof'
       AND column_name IN ('generated_at', 'consent_comparison_result',
                           'consent_important_matters', 'consent_personal_info');
    IF v_cnt <> 4 THEN
        RAISE EXCEPTION '058 failed: run_proof is missing rebuild columns (found % of 4)', v_cnt;
    END IF;

    -- ── 横断: RLS が全 public テーブルで有効かつ強制であること ───────────
    SELECT count(*) INTO v_cnt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r'
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION 'cross-check failed: % public table(s) without RLS enabled+forced', v_cnt;
    END IF;

    -- ── 横断: SECURITY DEFINER 関数が search_path を固定していること ─────
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND prosecdef
       AND NOT (coalesce(array_to_string(proconfig, ','), '') LIKE '%search_path%');
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION 'cross-check failed: % SECURITY DEFINER function(s) without a fixed search_path', v_cnt;
    END IF;

    RAISE NOTICE '050_058_check: ALL CHECKS PASSED';
END;
$$;
