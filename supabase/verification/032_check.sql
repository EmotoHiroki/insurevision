-- ============================================================================
-- 032_check.sql
--
-- migration 032（snapshotのredundancy_decisions・resolution_memoへの
-- 確定後凍結チェック付き書込み関数の追加）の検証。
--
-- 【2026-07-31追記・重要な訂正】
-- 本ファイル作成時点（032適用直後）、以下の記述の§2にある「保存機能は
-- 本番で常に権限エラーにより失敗していた」という診断は**誤りだった**。
-- 診断に使用した`has_table_privilege(...,'UPDATE')`はテーブル全体の権限
-- のみを見ており、024が既に付与していた列単位のUPDATE権限
-- （redundancy_decisions・resolution_memoの2列のみ）を検出できていな
-- かった。実際には直接のData API経由PATCHは正常に成功しており、機能は
-- 停止していなかった。
--
-- 実際に存在した問題は、034で発見・是正した「024由来の列単位付与には
-- 確定後凍結の検査が一切なく、finalized状態のrunに対しても直接PATCHが
-- 成立してしまう」という、032が追加した保護の迂回経路である。詳細・
-- 訂正後の実測記録は`034_check.sql`を参照。
--
-- auth.uid()を要する経路のため、平のSQLセッションでは実行結果を再現できない
-- （015・030・031と同じ制約）。カタログレベルの権限確認＋実測記録の2部構成。
-- ============================================================================

DO $$
DECLARE
    v_redundancy_fn oid;
    v_memo_fn       oid;
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
    -- 【2026-08-06修正】引数構成を直書きしていたため、migration 061で
    -- 旧2引数版 update_snapshot_redundancy_decisions(uuid, jsonb) を削除した
    -- 時点で、本DOブロックが 42883（該当関数なし）で停止するようになっていた。
    -- しかも停止位置が以降の検査より手前であるため、resolution_memo側の検査も
    -- 含めて1件も実行されない状態だった。
    -- 引数構成は後続のmigrationで変わりうるので、名前からoidを解決する。
    SELECT p.oid INTO v_redundancy_fn FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'update_snapshot_redundancy_decisions';
    IF v_redundancy_fn IS NULL THEN
        RAISE EXCEPTION '032 verify failed: update_snapshot_redundancy_decisions not found';
    END IF;

    SELECT p.oid INTO v_memo_fn FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname = 'update_snapshot_resolution_memo';
    IF v_memo_fn IS NULL THEN
        RAISE EXCEPTION '032 verify failed: update_snapshot_resolution_memo not found';
    END IF;

    IF NOT has_function_privilege('authenticated', v_redundancy_fn, 'EXECUTE') THEN
        RAISE EXCEPTION '032 verify failed: authenticated cannot execute update_snapshot_redundancy_decisions';
    END IF;
    IF has_function_privilege('anon', v_redundancy_fn, 'EXECUTE') THEN
        RAISE EXCEPTION '032 verify failed: anon can execute update_snapshot_redundancy_decisions';
    END IF;
    IF NOT has_function_privilege('authenticated', v_memo_fn, 'EXECUTE') THEN
        RAISE EXCEPTION '032 verify failed: authenticated cannot execute update_snapshot_resolution_memo';
    END IF;
    IF has_function_privilege('anon', v_memo_fn, 'EXECUTE') THEN
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
-- ことを確認した。当時は「authenticatedがUPDATE権限を一切保持していない」
-- と誤診断したが、これは誤り（上記2026-07-31追記を参照）。実際には
-- 024由来の列単位UPDATE権限により保存機能自体は動作していた。
--
-- 1. 正しいagencyのactive operatorがresolution_memoを保存
--    -> 032適用後・034適用前の状態で成功。DBの実値を直接確認し反映を確認。
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
