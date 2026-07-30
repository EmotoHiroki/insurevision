-- ============================================================================
-- 032_check.sql
--
-- migration 032（snapshotのredundancy_decisions・resolution_memo保存の
-- 復旧・確定後凍結）の検証。
--
-- auth.uid()を要する経路のため、平のSQLセッションでは実行結果を再現できない
-- （015・030・031と同じ制約）。カタログレベルの権限確認＋実測記録の2部構成。
-- ============================================================================

DO $$
BEGIN
    -- ── snapshot: authenticatedの直接UPDATE権限は元々なく（今回も付与しない）、
    --    2関数経由でのみ更新可能であること ──────────────────────────────
    IF has_table_privilege('authenticated', 'public.snapshot', 'UPDATE') THEN
        RAISE EXCEPTION '032 verify failed: authenticated has direct UPDATE on snapshot (should only go through the functions)';
    END IF;

    -- ── anonの不要な直接権限（INSERT・UPDATE）が剥奪されていること ───────
    IF has_table_privilege('anon', 'public.snapshot', 'INSERT') THEN
        RAISE EXCEPTION '032 verify failed: anon still has INSERT on snapshot';
    END IF;
    IF has_table_privilege('anon', 'public.snapshot', 'UPDATE') THEN
        RAISE EXCEPTION '032 verify failed: anon still has UPDATE on snapshot';
    END IF;

    -- ── 2関数: authenticatedのみEXECUTE可、anon・PUBLICは不可 ────────────
    IF NOT has_function_privilege('authenticated', 'public.update_snapshot_redundancy_decisions(uuid, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION '032 verify failed: authenticated cannot execute update_snapshot_redundancy_decisions';
    END IF;
    IF has_function_privilege('anon', 'public.update_snapshot_redundancy_decisions(uuid, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION '032 verify failed: anon can execute update_snapshot_redundancy_decisions';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.update_snapshot_resolution_memo(uuid, text)', 'EXECUTE') THEN
        RAISE EXCEPTION '032 verify failed: authenticated cannot execute update_snapshot_resolution_memo';
    END IF;
    IF has_function_privilege('anon', 'public.update_snapshot_resolution_memo(uuid, text)', 'EXECUTE') THEN
        RAISE EXCEPTION '032 verify failed: anon can execute update_snapshot_resolution_memo';
    END IF;

    RAISE NOTICE '032 verify passed: snapshot has no direct UPDATE grant for authenticated/anon, both notes functions are authenticated-only';
END $$;


-- ============================================================================
-- 実測記録（実HTTP・実JWT、2026-07-31、agency a0000000-...-001のテスト用
-- run 11111111.../snapshot 22222222...を使用）:
--
-- 経緯: #40の横展開調査中、`src/app/run/[id]/page.tsx`が現在も
-- snapshotのredundancy_decisions・resolution_memoを直接updateしている
-- ことを確認したところ、authenticatedがsnapshotへのUPDATE権限を一切
-- 保持していないことが判明した（田島様からの指摘ではなく自己発見）。
-- つまりこの保存機能は本番で常に権限エラーにより失敗していた。
--
-- 1. 正しいagencyのactive operatorがresolution_memoを保存
--    -> 修正前は不可能だった操作が成功。DBの実値を直接確認し反映を確認。
-- 2. 同operatorがredundancy_decisionsを保存
--    -> 同様に成功を確認。
-- 3. 別agencyのoperatorが同snapshotへの保存を試行
--    -> 拒否（no active operator for the calling session。JWT_Cは
--       非activeなoperatorのため、この経路で検出）。
-- 4. pure anonがData API経由でsnapshotへの直接PATCHを試行
--    -> 拒否（42501 permission denied for table）。
-- 5. 対象runを一時的にrun_status='finalized'にした状態で、正しいagencyの
--    operatorがresolution_memoの保存を試行
--    -> 拒否（run not editable）。UI側のisEditable
--       （run_status IN ('draft','post_record_pending')）と同一の条件を
--       DB側でも保証できていることを確認。
--
-- 試験後、snapshotのredundancy_decisions・resolution_memoは元の状態
--（[]・NULL）へ、run_statusは'draft'へ復元済み。
-- ============================================================================
