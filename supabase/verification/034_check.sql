-- ============================================================================
-- 034_check.sql
--
-- migration 034（snapshotの列単位UPDATE権限の是正）の検証。
--
-- 032の診断誤りの訂正: 032作成時、has_table_privilegeのみでsnapshotへの
-- authenticated UPDATE権限を「なし」と誤判定していた。実際には024が
-- redundancy_decisions・resolution_memoの2列に列単位でUPDATEを付与して
-- おり、機能は動作していた。ただしこの列単位付与には確定後凍結の検査が
-- 一切なく、finalized状態のrunに対しても直接PATCHが成立してしまうこと
-- （032が追加した保護の実質的な無効化）を実測で確認した。034はこの
-- 列単位付与を剥奪し、032の2関数のみを唯一の書込み経路にする。
-- ============================================================================

DO $$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(col, ', ') INTO v_bad
      FROM unnest(ARRAY['redundancy_decisions','resolution_memo']) AS col
     WHERE has_column_privilege('authenticated','public.snapshot',col,'UPDATE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '034 verify failed: authenticated still has direct column UPDATE on -> %', v_bad;
    END IF;

    IF has_table_privilege('authenticated', 'public.snapshot', 'UPDATE') THEN
        RAISE EXCEPTION '034 verify failed: authenticated has table-level UPDATE on snapshot';
    END IF;

    RAISE NOTICE '034 verify passed: no direct UPDATE path remains on snapshot for authenticated (column or table level); update_snapshot_redundancy_decisions/update_snapshot_resolution_memo are the only write path';
END;
$$;

-- ============================================================================
-- 実測記録（実HTTP・実JWT、2026-07-31、agency a0000000-...-001のsnapshot
-- 22222222...、run 11111111...を使用）:
--
-- 1. 是正前の実測: 直接Data API経由のPATCH（resolution_memo）が、agency一致・
--    active operatorの条件下で**成功する**ことを確認（034適用前の状態）。
--    032作成時の「本番で機能が完全に停止していた」という記述は誤りであった。
-- 2. 是正前の実測（重大）: 対象runを一時的にrun_status='finalized'にした
--    状態で、同じ直接PATCHを試行 -> **成功してしまう**ことを確認。
--    032の関数が実装した確定後凍結チェックは、直接PATCH経路には一切
--    及んでいなかった（保護の迂回経路が実在した）。
-- 3. 034適用後の再測: 同じ直接PATCH（finalized状態のrun）-> 拒否
--    （42501 permission denied for table）。
-- 4. 034適用後、032のRPC経由（update_snapshot_resolution_memo）で同じ
--    finalized runに対して試行 -> 引き続き正しく拒否（run not editable）。
--    RPC経路の凍結チェック自体は034の影響を受けず健在。
--
-- 試験後、snapshot.resolution_memo・run.run_statusはすべて元の状態へ
-- 復元済み。
-- ============================================================================
