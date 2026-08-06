-- ============================================================================
-- 062_b1_ms1_restore_baseline_indexes_and_revoke_trigger_helper.sql
--
-- 「本番」と「新規DBへ001から通し適用した結果」を、テーブル権限だけでなく
-- インデックス・関数EXECUTE権限・バケット・既定権限まで含めて突き合わせた際に
-- 検出された差分のうち、migrationで是正すべき2点を扱う。
--
-- 【是正1】migration 001 が作成するインデックス7件が本番に存在しない
--   001_m1_schema.sql は `CREATE INDEX IF NOT EXISTS` で7件を作成するが、
--   本番にはこの7件が存在しなかった。本番は migration 運用を開始する前から
--   稼働していたため、001 の内容が本番へ完全には反映されていなかったことになる。
--   参照系の性能に関わるのみで、権限・RLS・証跡の正しさには影響しない。
--   `IF NOT EXISTS` 付きで作成するため、既に存在するDB（通し適用後の検証DB）へ
--   再実行しても無害。
--
-- 【是正2】`update_updated_at_column()` を anon / authenticated から実行可能な状態の解消
--   本番には Supabase がプロジェクト作成時に設定する既定権限
--   （`ALTER DEFAULT PRIVILEGES ... GRANT EXECUTE ON FUNCTIONS TO anon, authenticated,
--     service_role` 相当）が残っている。このため public スキーマに作成された関数は
--   明示的に REVOKE しない限り anon まで EXECUTE 可能になる。
--   業務用RPCは 024 以降の各migrationで個別に REVOKE 済みだが、
--   トリガー用ヘルパーである本関数だけが対象から漏れていた。
--
--   実害の評価: 本関数は戻り値が `trigger` 型であり、トリガー以外から呼び出すと
--   PostgreSQL が実行前に拒否する（`trigger` 型はSQLから直接呼べない）。
--   したがって、この権限を用いてデータを読む・書くことはできない。
--   ただし最小権限の原則からは付与されているべきではなく、また
--   「新規DBへ通し適用した結果」と本番を一致させるためにも解消する。
--
-- 【この migration で扱わないもの（意図的）】
--   ・既定権限（pg_default_acl）そのもの
--     本番に存在する Supabase 既定権限を migration で再現することはしない。
--     再現すると、以後 public に作られる全ての関数・テーブルが自動的に
--     anon へ開放されることになり、059 で確立した「明示的に許可したものだけを
--     許可する」方針と正面から矛盾する。新規DBに既定権限が無い状態は、
--     本番より厳しい（安全な）側の差分である。
--     アプリの動作は既定権限に依存していない（059適用後も実HTTP検証16件が
--     全て成功することで確認済み）。
--   ・`run-pdfs` バケット
--     本番にのみ存在し、どの migration も作成していない。オブジェクト0件、
--     ソース全体からの参照も0件で、Phase2-b以前の残置と考えられる。
--     削除は本番の実体を消す操作にあたるため、本migrationでは行わず、
--     取り扱いを完了報告書に記載してご判断を仰ぐ。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

-- ── 是正1: 001 のベースラインインデックスを本番へ揃える ──────────────────
CREATE INDEX IF NOT EXISTS idx_audit_event_run_id ON public.audit_event USING btree (run_id);
CREATE INDEX IF NOT EXISTS idx_audit_event_time   ON public.audit_event USING btree (occurred_at);
CREATE INDEX IF NOT EXISTS idx_candidate_run_id   ON public.candidate   USING btree (run_id);
CREATE INDEX IF NOT EXISTS idx_run_agency_id      ON public.run         USING btree (agency_id);
CREATE INDEX IF NOT EXISTS idx_run_operator_id    ON public.run         USING btree (operator_id);
CREATE INDEX IF NOT EXISTS idx_run_status         ON public.run         USING btree (run_status);
CREATE INDEX IF NOT EXISTS idx_snapshot_run_id    ON public.snapshot    USING btree (run_id);

-- ── 是正2: トリガー用ヘルパーのEXECUTE権限を剥奪 ────────────────────────
REVOKE ALL ON FUNCTION public.update_updated_at_column() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_updated_at_column() FROM anon;
REVOKE ALL ON FUNCTION public.update_updated_at_column() FROM authenticated;

-- ── 適用結果の自己検査 ────────────────────────────────────────────────────
DO $$
DECLARE
    v_missing text;
    v_oid     oid;
BEGIN
    -- 是正1: 7件が揃っていること
    SELECT string_agg(x.name, ', ') INTO v_missing
      FROM (VALUES
              ('idx_audit_event_run_id'), ('idx_audit_event_time'),
              ('idx_candidate_run_id'),   ('idx_run_agency_id'),
              ('idx_run_operator_id'),    ('idx_run_status'),
              ('idx_snapshot_run_id')
           ) AS x(name)
     WHERE NOT EXISTS (
              SELECT 1 FROM pg_indexes
               WHERE schemaname = 'public' AND indexname = x.name);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION '062 failed: baseline indexes still missing: %', v_missing;
    END IF;

    -- 是正2: anon / authenticated から実行できないこと
    SELECT p.oid INTO v_oid FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'update_updated_at_column';
    IF v_oid IS NULL THEN
        RAISE EXCEPTION '062 failed: update_updated_at_column not found';
    END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '062 failed: anon can still execute update_updated_at_column';
    END IF;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
        RAISE EXCEPTION '062 failed: authenticated can still execute update_updated_at_column';
    END IF;

    -- 退行防止: public.update_updated_at_column を使うトリガーが残っていること。
    -- EXECUTE権限は CREATE TRIGGER 時に検査され、発火時には検査されないため、
    -- 上記のREVOKEはトリガーの動作に影響しない。
    -- 注: storage スキーマにも同名の関数 storage.update_updated_at_column があり、
    -- storage.objects のトリガーはそちらを使う。名前だけで判定すると、
    -- public 側のトリガーが失われていても本検査が通ってしまうため、
    -- 必ず pronamespace で public 側に限定して数える。
    IF (SELECT count(*) FROM pg_trigger t
          JOIN pg_proc p ON p.oid = t.tgfoid
         WHERE NOT t.tgisinternal
           AND p.pronamespace = 'public'::regnamespace
           AND p.proname = 'update_updated_at_column') < 2 THEN
        RAISE EXCEPTION '062 failed: expected the public updated_at triggers (agency_config, agency_rule_override) to remain, found %',
            (SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
              WHERE NOT t.tgisinternal AND p.pronamespace = 'public'::regnamespace
                AND p.proname = 'update_updated_at_column');
    END IF;

    RAISE NOTICE '062: baseline indexes restored and trigger helper execute revoked';
END;
$$;
