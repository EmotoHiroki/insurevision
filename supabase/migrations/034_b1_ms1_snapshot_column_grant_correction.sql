-- ============================================================================
-- 034_b1_ms1_snapshot_column_grant_correction.sql
--
-- 背景（032の診断誤りの訂正。#44 新規DB通し適用の実施中に自ら発見）:
--   032の作業時、`has_table_privilege('authenticated','public.snapshot',
--   'UPDATE')` が false であることのみを根拠に「snapshotの直接保存機能は
--   本番で完全に機能していない」と誤って結論した。実際には024が
--   `redundancy_decisions`・`resolution_memo` の2列に対して列単位のUPDATE
--   （`GRANT UPDATE (redundancy_decisions, resolution_memo) ON TABLE
--   snapshot TO authenticated`）を付与済みであり、`has_table_privilege`は
--   テーブル全体の権限のみを見るため、この列単位の付与を検出できていな
--   かった。実測の結果、直接PATCHは実際には成功しており、機能停止は
--   していなかった。
--
--   一方、実際に存在した問題は別にある。032で追加した
--   `update_snapshot_redundancy_decisions`・`update_snapshot_resolution_memo`
--   はagency照合と確定後凍結（run_status IN ('draft','post_record_pending')
--   のみ許可）を検査するが、024由来の列単位GRANTが残ったままのため、
--   直接のData API経由PATCHが今も並行して可能であり、**この直接経路には
--   凍結チェックが一切ない**。実測で、runを'finalized'にした状態でも
--   直接PATCHがそのまま成立することを確認した（032が追加した保護を
--   実質的に無効化する経路が残っていた）。
--
-- 対応: 024が付与した列単位のUPDATE権限を剥奪し、032の2関数のみを
--   唯一の書込み経路にする。
-- ============================================================================

REVOKE UPDATE (redundancy_decisions, resolution_memo) ON TABLE public.snapshot FROM authenticated;

-- ── 自己検査 ────────────────────────────────────────────────────────────
DO $$
DECLARE v_bad text;
BEGIN
    SELECT string_agg(col, ', ') INTO v_bad
      FROM unnest(ARRAY['redundancy_decisions','resolution_memo']) AS col
     WHERE has_column_privilege('authenticated','public.snapshot',col,'UPDATE');
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '034 verify failed: authenticated still has direct column UPDATE on -> %', v_bad;
    END IF;
    RAISE NOTICE '034 verify passed: direct column-level UPDATE on snapshot.redundancy_decisions/resolution_memo revoked; update_snapshot_redundancy_decisions/update_snapshot_resolution_memo (032) are now the only write path';
END;
$$;
