-- ============================================================================
-- 017_b1_ms1_finalize_run_execute_lockdown.sql
--
-- 状態: 本番適用済み（台帳 version 20260727160326）。実行そのものの正確な
--       時刻・実行ロールは記録していない（ダッシュボードのSQLエディタ経由で
--       適用したため。016のようにトランザクション内で now()・current_user を
--       同時に取得していない）。
--
-- 本ファイルは、本番へ実際に実行し台帳へ登録した6文と一致させている
-- （田島様2026-07-27 23:41ご指摘4に対応。016と記載方法を統一）。
--
-- 自己検査は本ファイルに含めない。詳細は
-- `supabase/verification/016_017_post_apply_checks.sql` を参照。
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
--   本ファイル作成当時は「anonとして実際に実行する試験は未実施」であったが、
--   その後 anon キーのみで /rest/v1/rpc/finalize_run および
--   /rest/v1/rpc/get_my_agency_id を実際に呼び出し、いずれも
--   42501 permission denied（HTTP 401）で拒否されることを実測で確認済み。
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
--   - operator.is_active の確認（018で全RLSポリシーの基点であるget_my_agency_id()
--     自体に追加済み。finalize_run内で直接operator.is_activeを見る形にはしていない）
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
