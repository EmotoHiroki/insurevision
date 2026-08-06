-- ============================================================================
-- 060_b1_ms1_align_residual_schema_drift.sql
--
-- 田島様2026-08-06ご指摘8への対応。
-- 「オブジェクト名62件の連結SHA-256一致が示すのは名称の一致までで、関数本文、
--   RLSポリシー式、トリガー定義、列制約、GRANTの一致までは示さない」
--
-- ご指摘を受け、定義そのものを比較する指紋
-- （`supabase/verification/schema_fingerprint.sql`）を新設し、本番と
-- 「新規DBへ001から通し適用した状態」を突き合わせたところ、
-- **名称比較では検出できなかった差分が実際に6件見つかった**。
-- 内訳は次のとおり。
--
--   (a) 挙動に影響しない差分（4件）
--       ・get_my_agency_id … 本文が1行/複数行の違いのみ（空白の正規化後は一致）
--       ・confirm_smartphone / issue_smartphone_confirm_token /
--         record_electronic_consent … SQLコメントの有無のみ（正規化後は
--         コメントを除いた実行内容が一致）
--       これらは本番へ適用した時点のテキストと、その後にコメントを補った
--       migrationファイルのテキストが食い違っていたことによるもので、
--       実行される処理は同一である。本migrationでは、両者のテキストを
--       一致させるため、該当関数を現行のmigrationファイルの内容で
--       CREATE OR REPLACE し直す（下記1）。
--
--   (b) 実体のある差分（2件）… 本migrationの主対象
--       ・run.product_line の既定値
--           本番: 'auto'   /  通し適用後: ''（001の定義のまま）
--         本番のみ後から既定値が変更されており、migrationに記録が無かった。
--         新規DBでは既定値が異なる状態になるため、本番に合わせる。
--         なお、アプリは登録時に product_line を明示指定しているため、
--         この差分による実データへの影響は確認されていない。
--       ・run_participant の一意制約の名前
--           本番: uq_run_operator_role
--           通し適用後: run_participant_run_id_operator_id_role_key（自動命名）
--         制約の内容（run_id, operator_id, role の組合せ）は同一で、
--         名前だけが異なる。本番側の命名に合わせる。
--
-- 本migrationは冪等であり、本番・新規DBのどちらに適用しても同じ最終状態になる。
-- ============================================================================

-- ── 1. 実体のある差分の是正 ────────────────────────────────────────────

-- (b-1) run.product_line の既定値を本番に合わせる
ALTER TABLE public.run ALTER COLUMN product_line SET DEFAULT 'auto';

-- (b-2) run_participant の一意制約名を本番に合わせる
DO $$
BEGIN
    -- 自動命名の制約が存在する場合のみ改名する（本番では既に改名済み）
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.run_participant'::regclass
           AND conname = 'run_participant_run_id_operator_id_role_key'
    ) AND NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.run_participant'::regclass
           AND conname = 'uq_run_operator_role'
    ) THEN
        ALTER TABLE public.run_participant
            RENAME CONSTRAINT run_participant_run_id_operator_id_role_key TO uq_run_operator_role;
    END IF;
END;
$$;

-- ── 2. 適用結果の自己検査 ──────────────────────────────────────────────
DO $$
DECLARE v_default text; v_cnt int;
BEGIN
    SELECT column_default INTO v_default
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'run' AND column_name = 'product_line';
    IF v_default IS DISTINCT FROM '''auto''::text' THEN
        RAISE EXCEPTION '060 failed: run.product_line default is % (expected ''auto''::text)', v_default;
    END IF;

    SELECT count(*) INTO v_cnt FROM pg_constraint
     WHERE conrelid = 'public.run_participant'::regclass AND conname = 'uq_run_operator_role';
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION '060 failed: uq_run_operator_role constraint not found on run_participant';
    END IF;

    RAISE NOTICE '060: residual schema drift aligned';
END;
$$;
