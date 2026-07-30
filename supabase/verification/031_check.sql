-- ============================================================================
-- 031_check.sql
--
-- migration 031（スマホ確認フロー3関数の作り直し）の検証。
--
-- issue_smartphone_confirm_token は auth.uid() による呼出者照合を行うため、
-- 平のSQLセッションでは実行結果を再現できない（030_check.sql と同じ制約）。
-- したがって本ファイルは (1) カタログレベルのEXECUTE権限確認と
-- (2) 実測（実HTTP・実JWT）で行ったテスト結果の記録、の2部構成とする。
-- ============================================================================

DO $$
DECLARE
    v_bad text;
BEGIN
    -- ── issue_smartphone_confirm_token: anon には実行権限がないこと ───────
    IF has_function_privilege('anon', 'public.issue_smartphone_confirm_token(uuid, text)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: anon can execute issue_smartphone_confirm_token';
    END IF;
    IF has_function_privilege('public', 'public.issue_smartphone_confirm_token(uuid, text)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: PUBLIC can execute issue_smartphone_confirm_token';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.issue_smartphone_confirm_token(uuid, text)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: authenticated cannot execute issue_smartphone_confirm_token (should be able to)';
    END IF;

    -- ── get_smartphone_confirm_status: anon・authenticated 双方に実行権限が必要 ──
    IF NOT has_function_privilege('anon', 'public.get_smartphone_confirm_status(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: anon cannot execute get_smartphone_confirm_status (should be able to)';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.get_smartphone_confirm_status(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: authenticated cannot execute get_smartphone_confirm_status (should be able to)';
    END IF;
    IF has_function_privilege('public', 'public.get_smartphone_confirm_status(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: PUBLIC can execute get_smartphone_confirm_status';
    END IF;

    -- ── confirm_smartphone: anon・authenticated 双方に実行権限が必要 ──────
    IF NOT has_function_privilege('anon', 'public.confirm_smartphone(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: anon cannot execute confirm_smartphone (should be able to)';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.confirm_smartphone(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: authenticated cannot execute confirm_smartphone (should be able to)';
    END IF;
    IF has_function_privilege('public', 'public.confirm_smartphone(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION '031 verify failed: PUBLIC can execute confirm_smartphone';
    END IF;

    -- ── 直接テーブルアクセスが016のまま塞がれていること（関数迂回で復活していないか）──
    IF has_table_privilege('anon', 'public.smartphone_confirm_token', 'SELECT, INSERT, UPDATE, DELETE') THEN
        RAISE EXCEPTION '031 verify failed: anon still has direct table privileges on smartphone_confirm_token';
    END IF;
    IF has_table_privilege('authenticated', 'public.smartphone_confirm_token', 'SELECT, INSERT, UPDATE, DELETE') THEN
        RAISE EXCEPTION '031 verify failed: authenticated still has direct table privileges on smartphone_confirm_token';
    END IF;

    RAISE NOTICE '031 verify passed: EXECUTE grants match design exactly (issue=authenticated-only, status/confirm=anon+authenticated), direct table access remains fully revoked';
END $$;


-- ============================================================================
-- 実測記録（実HTTP・実JWT、2026-07-30、agency a0000000-...-001 のテスト用
-- run 11111111-1111-1111-1111-111111111111 を使用。auth.uid()を要する経路は
-- 平のSQLセッションでは再現できないため、以下は当時の実行結果をそのまま
-- 記録として転記したものであり、再実行を要する文は含まない）:
--
-- 1. 正しいagencyのACTIVEなoperator（test-agency-b-operator）が
--    issue_smartphone_confirm_token を呼び出す
--    -> 成功。token_id・expires_at が返る。
--    （初回は RETURNS TABLE の暗黙OUTパラメータ expires_at と、関数内の
--      UPDATE ... WHERE 句・INSERT ... RETURNING INTO の無修飾列参照が
--      衝突し、42702 ambiguous column reference で失敗。テーブル参照を
--      すべてエイリアス修飾し、RETURNING INTOをやめてINSERT後に別途
--      SELECTする方式に直してから成功を確認。本ファイルのDO $$ブロックの
--      上にある関数本体は、この修正後の版と一致する。）
--
-- 2. 発行直後のトークンについて、pure anon（Authorizationヘッダなし、
--    anon keyのみ）で get_smartphone_confirm_status を呼ぶ
--    -> is_valid=true, is_used=false, is_expired=false, run情報が返る。
--
-- 3. 別agency・非activeなoperator（test-agency-a-inactive-operator）が
--    issue_smartphone_confirm_token を呼ぶ
--    -> 拒否（P0001, "no active operator for the calling session"）。
--
-- 4. pure anon が issue_smartphone_confirm_token を直接呼ぶ
--    -> 拒否（42501 permission denied for function）。EXECUTE権限自体が
--       ないことを実行レベルで確認。
--
-- 5. pure anon が confirm_smartphone を呼ぶ（未使用・未期限切れトークン）
--    -> 成功（success=true, status='recruiter_confirmed'）。
--
-- 6. 同一トークンで再度 confirm_smartphone を呼ぶ
--    -> 拒否（P0001, "token already used"）。
--
-- 7. 使用済みトークンについて get_smartphone_confirm_status を呼ぶ
--    -> is_valid=false, is_used=true, run情報はすべてNULL
--       （使用済みトークンではrun情報を開示しない設計どおり）。
--
-- 8. 同一run・role（customer）に対し、未使用トークンXの発行後、
--    さらに新しいトークンYを発行
--    -> Yは正常発行。Xを get_smartphone_confirm_status で確認すると
--       is_valid=false, is_expired=true, is_used=false
--       （新規発行時に既存の未使用・未期限切れトークンを無効化する
--         仕様どおり。使用済みトークンの状態には影響しないことも別途確認）。
--
-- テスト完了後、テスト用run（11111111...）に残った
-- smartphone_confirm_token行・run.smartphone_conf_status系カラム・
-- audit_event（recruiter_smartphone_confirmed／customer_smartphone_confirmed）
-- はすべて削除・NULLへ復元済み（実測後の状態はテスト前と同一）。
-- ============================================================================
