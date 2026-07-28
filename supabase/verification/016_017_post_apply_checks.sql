-- ============================================================================
-- 016_017_post_apply_checks.sql
--
-- 重要: これは migration ではない。適用対象のオブジェクトを作成・変更する
-- 文は一切含まない。migrations/016・017 が意図どおりの状態を達成したかを
-- 事後に確認するための、独立した検証SQLである。
--
-- migrations/ ディレクトリではなくこのディレクトリに置いているのは、
-- 通し適用ツール（001→NNNを順に流す運用）に、検証専用のファイルが
-- migrationそのものと誤って混在させられないようにするため。
--
-- 実行方法: migrations/016・017を適用した直後に、本ファイルを別途・
-- 手動で実行する。本ファイルの各DOブロックは、条件を満たさない場合に
-- 例外を送出するが、その例外は本ファイル自身の実行を止めるだけであり、
-- 016・017 で既に実行・コミットされた内容を巻き戻すものではない
-- （016・017の適用時点で、この検証は同一トランザクション内では実行されて
-- いない。詳細は末尾の「時系列の整理」を参照）。
-- ============================================================================

-- ── 016 の検証: smartphone_confirm_token ───────────────────────────────
DO $$
DECLARE
    v_rls_enabled  boolean;
    v_rls_forced   boolean;
    v_policy_count integer;
    v_remaining    text;
BEGIN
    SELECT c.relrowsecurity, c.relforcerowsecurity
      INTO v_rls_enabled, v_rls_forced
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = 'smartphone_confirm_token';

    IF v_rls_enabled IS DISTINCT FROM true THEN
        RAISE EXCEPTION '016 verify failed: RLS is not enabled on smartphone_confirm_token';
    END IF;
    IF v_rls_forced IS DISTINCT FROM true THEN
        RAISE EXCEPTION '016 verify failed: RLS is not FORCEd on smartphone_confirm_token';
    END IF;

    SELECT count(*) INTO v_policy_count FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'smartphone_confirm_token';
    IF v_policy_count <> 0 THEN
        RAISE EXCEPTION '016 verify failed: expected 0 policies, found %', v_policy_count;
    END IF;

    SELECT string_agg(format('%s:%s', g.grantee, g.priv), ', ' ORDER BY g.grantee, g.priv)
      INTO v_remaining
      FROM (
          SELECT r.rolname AS grantee, p.priv
            FROM (VALUES ('public'), ('anon'), ('authenticated')) AS r(rolname)
           CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'),
                              ('TRUNCATE'), ('REFERENCES'), ('TRIGGER'), ('MAINTAIN')) AS p(priv)
           WHERE has_table_privilege(r.rolname, 'public.smartphone_confirm_token', p.priv)
      ) g;
    IF v_remaining IS NOT NULL THEN
        RAISE EXCEPTION '016 verify failed: privileges remain -> %', v_remaining;
    END IF;

    RAISE NOTICE '016 verify passed: RLS enabled+forced, 0 policies, no privileges for PUBLIC/anon/authenticated (8 privileges checked, incl. MAINTAIN)';
END;
$$;

-- ── 017 の検証: finalize_run / get_my_agency_id ────────────────────────
DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(format('%s/%s', r.rolname, p.proname), ', ')
      INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     CROSS JOIN (VALUES ('public'), ('anon')) AS r(rolname)
     WHERE n.nspname = 'public'
       AND p.proname IN ('finalize_run', 'get_my_agency_id')
       AND has_function_privilege(r.rolname, p.oid, 'EXECUTE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '017 verify failed: EXECUTE still present -> %', v_bad;
    END IF;

    IF NOT has_function_privilege('authenticated',
            'public.finalize_run(uuid,text,text,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION '017 verify failed: authenticated lost EXECUTE on finalize_run';
    END IF;

    -- 田島様2026-07-27 23:41ご指摘7のとおり、finalize_runだけでなく
    -- get_my_agency_id についても authenticated の保持を検査する。
    IF NOT has_function_privilege('authenticated',
            'public.get_my_agency_id()', 'EXECUTE') THEN
        RAISE EXCEPTION '017 verify failed: authenticated lost EXECUTE on get_my_agency_id';
    END IF;

    RAISE NOTICE '017 verify passed: PUBLIC/anon have no EXECUTE on finalize_run or get_my_agency_id; authenticated retains both';
END;
$$;

-- ============================================================================
-- 時系列の整理（田島様2026-07-27 23:41ご指摘4への回答）
--
-- 016について、本番で実際に何が起きたかを4つの対象に分けて整理する。
--
-- (a) 本番で実行されたSQL:
--     ALTER TABLE ... ENABLE ROW LEVEL SECURITY;
--     ALTER TABLE ... FORCE ROW LEVEL SECURITY;
--     REVOKE ALL ... FROM PUBLIC;
--     REVOKE ALL ... FROM anon;
--     REVOKE ALL ... FROM authenticated;
--     （5文。Supabase MCPの execute_sql 経由で実行）
--
-- (b) 台帳（supabase_migrations.schema_migrations）に記録した内容:
--     version 20260727101932, name '016_b1_ms1_smartphone_token_emergency_lockdown'
--     statements列は (a) の5文と完全一致（実測済み）
--
-- (c) 現在のリポジトリファイル（migrations/016_....sql、本整理後）:
--     (a)(b) と同一の5文のみ。以前のファイルには自己検査のDOブロックが
--     追加で含まれていたが、これは本整理で本ファイル（検証専用）へ分離した。
--
-- (d) 分離後の検証SQL（本ファイル）:
--     016適用直後に、(a)とは別のexecute_sql呼出しとして実行し、
--     「016 self-check passed」の通知を得た。すなわち自己検査は
--     本番に対して実行されたが、(a)の5文と同一トランザクションでは
--     なかった。ご指摘のとおり、自己検査が失敗した場合に(a)を
--     自動的に巻き戻す構成には元々なっていなかった。
--
-- 017についても同様に整理する。
--
-- (a) 本番で実行されたSQL: migrations/017_....sql の現行6文
--     （REVOKE×4・GRANT×2。ダッシュボードのSQLエディタ経由で実行）
-- (b) 台帳: version 20260727160326、statements列は(a)と完全一致（実測済み）
-- (c) 現在のリポジトリファイル: (a)(b)と同一の6文のみ
-- (d) 分離後の検証SQL: 本ファイル。017適用後、has_function_privilege による
--     確認に加え、anon キーのみで実際に /rest/v1/rpc/finalize_run と
--     /rest/v1/rpc/get_my_agency_id を呼び出し、42501（HTTP 401）で
--     拒否されることを実測した。
-- ============================================================================
