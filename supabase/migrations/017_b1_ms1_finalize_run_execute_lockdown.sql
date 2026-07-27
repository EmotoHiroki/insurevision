-- ============================================================================
-- 017_b1_ms1_finalize_run_execute_lockdown.sql
--
-- 状態: 本番適用済み（2026-07-27 16:03 UTC。has_function_privilege により
--       PUBLIC/anon=false・authenticated=true を確認済み）
--
-- 目的: SECURITY DEFINER 関数に対する PUBLIC / anon の EXECUTE 権限を剥奪する。
--
-- 背景（田島様2026-07-27 23:41ご指摘8「関数の棚卸しが未実施」に基づく調査結果）:
--
--   `public.finalize_run` は以下の状態にある。
--     - SECURITY DEFINER（所有者 postgres。postgres は rolbypassrls=true のため
--       関数内の全DML操作はRLSを一切評価しない）
--     - proacl に `=X/postgres` が含まれる。すなわち **PUBLIC に EXECUTE が付与**
--       されており、`has_function_privilege('anon', ..., 'EXECUTE')` は true。
--       Supabase では public スキーマの関数は PostgREST 経由で
--       `/rest/v1/rpc/finalize_run` として公開されるため、anon キーだけで到達しうる。
--     - 関数本体に **呼出者の照合が一切ない**。`p_operator_id` を引数で受け取り、
--       その値をそのまま `run.finalized_by` と `audit_event.operator_id` に書き込む。
--     - `run` の更新条件は `WHERE id = p_run_id AND run_status = 'draft'` のみで、
--       **代理店の照合がない**。
--     - `search_path` が未設定。
--
--   結果として、理論上は未認証の呼出しにより、任意の draft run を finalized へ遷移
--   させ、`pdf_object_key` / `pdf_sha256` を任意の値で記録し、さらに
--   `run_finalized` と `consent_comparison_result` の audit_event を
--   **任意の operator_id を詐称して**作成できる。
--   audit_event の INSERT ポリシー（012/013 で導入した operator_id 本人性検査）は、
--   SECURITY DEFINER によりRLSごと迂回されるため機能しない。
--
--   本番の draft run は18件（2026-07-27時点）。
--
-- 重要・証明の範囲について:
--   上記のうち「anon に EXECUTE がある」「関数本体に照合がない」「SECURITY DEFINER
--   かつ所有者が BYPASSRLS を持つ」は、いずれもカタログおよび関数定義から確認した
--   事実である。一方、**実際に anon として本関数を実行する試験は未実施**である
--   （検証セッションが読取専用ロールに切り替わったため）。したがって上記の帰結は
--   定義からの導出であり、実測ではない。実測は本migrationの適用前後に取得する。
--
-- 本migrationの範囲（緊急遮断のみ）:
--   PUBLIC と anon から EXECUTE を剥奪し、authenticated にのみ付与する。
--   アプリ側の `/api/finalize` は createServerSupabaseClient()（ANON KEY ＋
--   ログインセッション）を使用しており `authenticated` として実行されるため、
--   本剥奪によって既存の正規経路は影響を受けない。
--
-- 本migrationに含めないもの（第3段階・設計協議の対象）:
--   - 呼出者照合（auth.uid() から operator を解決し、p_operator_id を引数で
--     受け取らない形へ変更する）
--   - 代理店照合（対象 run が呼出者の代理店に属することの検査）
--   - search_path の是正（本体が非修飾の `run` / `audit_event` を参照しているため、
--     search_path='' を設定するには本体の完全修飾が必須。同時に行う）
--   - operator.is_active の確認
--   これらを行わない限り、**authenticated であれば他代理店の run を確定できる状態は
--   残る**。本migrationは未認証経路のみを塞ぐものであり、恒久是正ではない。
-- ============================================================================

-- ── finalize_run ────────────────────────────────────────────────────────
REVOKE EXECUTE ON FUNCTION public.finalize_run(uuid, text, text, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.finalize_run(uuid, text, text, uuid, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.finalize_run(uuid, text, text, uuid, boolean) TO authenticated;

-- ── get_my_agency_id ────────────────────────────────────────────────────
-- 全RLSポリシーの基点。anon が実行しても NULL を返すのみで直接の危険は小さいが、
-- 未認証に公開する必要がないため同時に剥奪する。
REVOKE EXECUTE ON FUNCTION public.get_my_agency_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_agency_id() FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_my_agency_id() TO authenticated;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(format('%s/%s', r.rolname, p.proname), ', ')
      INTO v_bad
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     CROSS JOIN (VALUES ('public'), ('anon')) AS r(rolname)
     WHERE n.nspname = 'public'
       AND p.proname IN ('finalize_run', 'get_my_agency_id')
       AND has_function_privilege(r.rolname, p.oid, 'EXECUTE');

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '017 self-check failed: EXECUTE still present -> %', v_bad;
    END IF;

    -- authenticated には残っていること（アプリの正規経路を壊していないこと）
    IF NOT has_function_privilege('authenticated',
            'public.finalize_run(uuid,text,text,uuid,boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION '017 self-check failed: authenticated lost EXECUTE on finalize_run';
    END IF;

    RAISE NOTICE '017 self-check passed';
END;
$$;
