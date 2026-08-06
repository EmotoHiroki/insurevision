-- ============================================================================
-- 059_062_check.sql
--
-- migration 059〜062 の適用結果を検証する。
--
-- 既存の `supabase/verification/050_058_check.sql` は 050〜058 を対象として
-- おり、その後に追加した 059〜062 を再検証するものが無かった。本ファイルは
-- 同じ方式で、第三者がそのまま再実行して合否を判定できる形にしてある。
--
-- 実行方法:
--   psql "<接続文字列>" -f supabase/verification/059_062_check.sql
--   または Supabase SQL Editor に全文を貼り付けて実行
--
-- 判定:
--   すべて合格の場合のみ最後に「059_062_check: ALL CHECKS PASSED」を出力する。
--   1件でも不合格があれば、その時点で EXCEPTION を送出して停止する。
--   不合格時は、期待値だけでなく実際に観測された値もメッセージに含める。
--
-- 注意:
--   本スクリプトは読み取りのみで、データ・スキーマ・権限を一切変更しない。
--   接続情報・トークン等の秘密情報は含まない。
--   `information_schema` は接続中のロールから見える権限のみを返すため、
--   権限の検査を正しく行うには postgres 相当のロールで実行すること。
-- ============================================================================

DO $$
DECLARE
    v_cnt    int;
    v_txt    text;
    v_extra  text;
    v_miss   text;
    v_oid    oid;
BEGIN
    -- ── 059: テーブル権限の許可リスト ───────────────────────────────────
    -- 期待値は 059 の GRANT 文からそのまま起こしたものであり、本番の現在値を
    -- 写したものではない。許可リストに無い権限が1件でも増えれば不合格になる。
    WITH expected(grantee, table_name, privilege_type) AS (
        VALUES
            -- authenticated への明示的な付与（059 (2)）
            ('authenticated'::text, 'run'::text,                  'SELECT'::text),
            ('authenticated',       'run',                        'INSERT'),
            ('authenticated',       'run',                        'UPDATE'),
            ('authenticated',       'operator',                   'SELECT'),
            ('authenticated',       'audit_event',                'SELECT'),
            ('authenticated',       'audit_event',                'INSERT'),
            ('authenticated',       'snapshot',                   'SELECT'),
            ('authenticated',       'snapshot',                   'INSERT'),
            ('authenticated',       'candidate',                  'SELECT'),
            ('authenticated',       'agency_config',              'SELECT'),
            ('authenticated',       'agency_rule_override',       'SELECT'),
            ('authenticated',       'property_profile',           'SELECT'),
            ('authenticated',       'intent_confirmation',        'SELECT'),
            ('authenticated',       'intent_confirmation',        'INSERT'),
            ('authenticated',       'intent_confirmation',        'UPDATE'),
            ('authenticated',       'csv_import_session',         'SELECT'),
            ('authenticated',       'csv_import_session',         'INSERT'),
            ('authenticated',       'csv_import_session',         'UPDATE'),
            ('authenticated',       'coverage_rule_master',       'SELECT'),
            ('authenticated',       'flood_zone_master',          'SELECT'),
            ('authenticated',       'insurance_category',         'SELECT'),
            ('authenticated',       'insurance_line',             'SELECT'),
            ('authenticated',       'restriction_reason_master',  'SELECT'),
            -- anon への明示的な付与（059 (3)）: 公開読取りのマスタ5表のみ
            ('anon',                'coverage_rule_master',       'SELECT'),
            ('anon',                'flood_zone_master',          'SELECT'),
            ('anon',                'insurance_category',         'SELECT'),
            ('anon',                'insurance_line',             'SELECT'),
            ('anon',                'restriction_reason_master',  'SELECT')
    ),
    observed AS (
        SELECT g.grantee::text AS grantee,
               g.table_name::text AS table_name,
               g.privilege_type::text AS privilege_type
          FROM information_schema.role_table_grants g
         WHERE g.table_schema = 'public'
           AND g.grantee IN ('anon', 'authenticated')
    )
    SELECT
        (SELECT string_agg(format('%s/%s/%s', grantee, table_name, privilege_type), ', '
                           ORDER BY grantee, table_name, privilege_type)
           FROM (SELECT * FROM observed EXCEPT SELECT * FROM expected) x),
        (SELECT string_agg(format('%s/%s/%s', grantee, table_name, privilege_type), ', '
                           ORDER BY grantee, table_name, privilege_type)
           FROM (SELECT * FROM expected EXCEPT SELECT * FROM observed) y)
      INTO v_extra, v_miss;

    IF v_extra IS NOT NULL THEN
        RAISE EXCEPTION '059 failed: grants outside the allow-list -> %', v_extra;
    END IF;
    IF v_miss IS NOT NULL THEN
        RAISE EXCEPTION '059 failed: allow-listed grants missing -> %', v_miss;
    END IF;

    -- 総数の一致（重複付与など、上の集合比較では消えてしまう差分を捕捉する）
    SELECT count(*) INTO v_cnt FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND grantee IN ('anon', 'authenticated');
    IF v_cnt <> 28 THEN
        RAISE EXCEPTION '059 failed: expected 28 table grants for anon+authenticated, found %', v_cnt;
    END IF;

    -- anon はマスタ5表の SELECT 以外を一切持たないこと
    SELECT count(*) INTO v_cnt FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND grantee = 'anon'
       AND (privilege_type <> 'SELECT'
            OR table_name NOT IN ('coverage_rule_master', 'flood_zone_master',
                                  'insurance_category', 'insurance_line',
                                  'restriction_reason_master'));
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '059 failed: anon holds % table privilege(s) outside the public master allow-list', v_cnt;
    END IF;

    -- deny-all を維持すべき3表（059 (4)）に権限が付いていないこと
    SELECT string_agg(format('%s/%s/%s', grantee, table_name, privilege_type), ', ')
      INTO v_txt
      FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND grantee IN ('anon', 'authenticated')
       AND table_name IN ('run_proof', 'run_participant', 'smartphone_confirm_token');
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION '059 failed: deny-all tables must not be granted -> %', v_txt;
    END IF;

    -- ── 060: 残存スキーマ差分の是正 ─────────────────────────────────────
    SELECT column_default INTO v_txt
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'run' AND column_name = 'product_line';
    IF v_txt IS DISTINCT FROM '''auto''::text' THEN
        RAISE EXCEPTION '060 failed: run.product_line default is % (expected ''auto''::text)',
            coalesce(v_txt, '(none)');
    END IF;

    SELECT count(*) INTO v_cnt FROM pg_constraint
     WHERE conrelid = 'public.run_participant'::regclass AND conname = 'uq_run_operator_role';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '060 failed: expected 1 constraint named uq_run_operator_role on run_participant, found %', v_cnt;
    END IF;

    -- 自動命名の旧制約名が残っていないこと（改名ではなく重複作成だった場合を捕捉する）
    SELECT count(*) INTO v_cnt FROM pg_constraint
     WHERE conrelid = 'public.run_participant'::regclass
       AND conname = 'run_participant_run_id_operator_id_role_key';
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION '060 failed: legacy constraint name run_participant_run_id_operator_id_role_key still present (% row(s))', v_cnt;
    END IF;

    -- ── 061: 補償重複の判断記録を専任関数側で行うこと ────────────────────
    SELECT count(*) INTO v_cnt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'update_snapshot_redundancy_decisions';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '061 failed: expected exactly 1 update_snapshot_redundancy_decisions, found % (旧2引数版が残っている可能性)', v_cnt;
    END IF;

    SELECT pronargs, prosrc, oid INTO v_cnt, v_txt, v_oid FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'update_snapshot_redundancy_decisions';
    IF v_cnt <> 5 THEN
        RAISE EXCEPTION '061 failed: update_snapshot_redundancy_decisions takes % argument(s) (expected 5)', v_cnt;
    END IF;

    IF v_txt NOT LIKE '%redundancy_resolution_recorded%' THEN
        RAISE EXCEPTION '061 failed: the function does not record redundancy_resolution_recorded';
    END IF;
    IF v_txt NOT LIKE '%INSERT INTO public.audit_event%' THEN
        RAISE EXCEPTION '061 failed: the function does not insert into public.audit_event';
    END IF;

    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '061 failed: authenticated cannot execute update_snapshot_redundancy_decisions';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '061 failed: anon can still execute update_snapshot_redundancy_decisions';
    END IF;

    -- ── 062: 001 のベースラインインデックスとトリガー用ヘルパーの権限 ────
    SELECT string_agg(x.name, ', ' ORDER BY x.name) INTO v_txt
      FROM (VALUES
              ('idx_audit_event_run_id'), ('idx_audit_event_time'),
              ('idx_candidate_run_id'),   ('idx_run_agency_id'),
              ('idx_run_operator_id'),    ('idx_run_status'),
              ('idx_snapshot_run_id')
           ) AS x(name)
     WHERE NOT EXISTS (
              SELECT 1 FROM pg_indexes
               WHERE schemaname = 'public' AND indexname = x.name);
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION '062 failed: baseline indexes missing: %', v_txt;
    END IF;

    SELECT p.oid INTO v_oid FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'update_updated_at_column';
    IF v_oid IS NULL THEN
        RAISE EXCEPTION '062 failed: public.update_updated_at_column not found';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '062 failed: anon can still execute public.update_updated_at_column';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '062 failed: authenticated can still execute public.update_updated_at_column';
    END IF;

    -- 退行防止: public.update_updated_at_column を使うトリガーが残っていること。
    -- EXECUTE権限は CREATE TRIGGER 時にのみ検査され、発火時には検査されないため、
    -- 上記のREVOKEはトリガーの動作に影響しない。
    -- 注: storage スキーマにも同名の関数 storage.update_updated_at_column があり、
    -- storage.objects のトリガーはそちらを使う。名前だけで判定すると public 側の
    -- トリガーが失われていても本検査が通ってしまうため、必ず pronamespace で
    -- public 側に限定して数える。
    SELECT count(*) INTO v_cnt
      FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
     WHERE NOT t.tgisinternal
       AND p.pronamespace = 'public'::regnamespace
       AND p.proname = 'update_updated_at_column';
    IF v_cnt < 2 THEN
        RAISE EXCEPTION '062 failed: expected at least 2 triggers on the public updated_at helper (agency_config, agency_rule_override), found %', v_cnt;
    END IF;

    -- ── 横断: RLS が全 public テーブルで有効かつ強制であること ───────────
    -- 059 で権限を明示化したあとも、行の可視性はRLSが決める前提を維持する。
    SELECT count(*) INTO v_cnt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r'
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION 'cross-check failed: % public table(s) without RLS enabled+forced', v_cnt;
    END IF;

    -- ── 横断: SECURITY DEFINER 関数が search_path を固定していること ─────
    SELECT string_agg(proname, ', ' ORDER BY proname) INTO v_txt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND prosecdef
       AND NOT (coalesce(array_to_string(proconfig, ','), '') LIKE '%search_path%');
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'cross-check failed: SECURITY DEFINER function(s) without a fixed search_path -> %', v_txt;
    END IF;

    RAISE NOTICE '059_062_check: ALL CHECKS PASSED';
END;
$$;
