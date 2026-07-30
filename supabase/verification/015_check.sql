-- ============================================================================
-- 015_check.sql
--
-- migration 015（第5段階: save_property_profile）の検証。
--
-- save_property_profile は auth.uid() による呼出者照合を行うため、
-- 平のSQLセッションでは実行結果を再現できない（030・031と同じ制約）。
-- したがって本ファイルは (1) カタログレベルの権限確認と
-- (2) 実測（実HTTP・実JWT）で行ったテスト結果の記録、の2部構成とする。
-- ============================================================================

DO $$
BEGIN
    -- ── property_profile: authenticatedはSELECTのみ、書込み権限はすべて剥奪されていること ──
    IF has_table_privilege('authenticated', 'public.property_profile', 'INSERT') THEN
        RAISE EXCEPTION '015 verify failed: authenticated still has INSERT on property_profile';
    END IF;
    IF has_table_privilege('authenticated', 'public.property_profile', 'UPDATE') THEN
        RAISE EXCEPTION '015 verify failed: authenticated still has UPDATE on property_profile';
    END IF;
    IF has_table_privilege('authenticated', 'public.property_profile', 'DELETE') THEN
        RAISE EXCEPTION '015 verify failed: authenticated still has DELETE on property_profile';
    END IF;
    IF NOT has_table_privilege('authenticated', 'public.property_profile', 'SELECT') THEN
        RAISE EXCEPTION '015 verify failed: authenticated lost SELECT on property_profile (should keep it)';
    END IF;

    -- ── save_property_profile: authenticatedのみEXECUTE可、anon・PUBLICは不可 ──
    IF NOT has_function_privilege('authenticated', 'public.save_property_profile(uuid, text, text, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION '015 verify failed: authenticated cannot execute save_property_profile (should be able to)';
    END IF;
    IF has_function_privilege('anon', 'public.save_property_profile(uuid, text, text, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION '015 verify failed: anon can execute save_property_profile';
    END IF;
    IF has_function_privilege('public', 'public.save_property_profile(uuid, text, text, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION '015 verify failed: PUBLIC can execute save_property_profile';
    END IF;

    -- ── last_save_id 列が存在すること ──────────────────────────────────
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='public' AND table_name='property_profile' AND column_name='last_save_id'
    ) THEN
        RAISE EXCEPTION '015 verify failed: property_profile.last_save_id column missing';
    END IF;

    RAISE NOTICE '015 verify passed: property_profile direct write access fully revoked from authenticated (SELECT kept), save_property_profile EXECUTE restricted to authenticated only';
END $$;

-- ── property_profile と対応するaudit_eventが常に1対1で存在するか（孤立行の検出）──
-- 期待値: 0行（last_save_idを持つ全行に対応するaudit_eventが存在する）
SELECT pp.run_id, pp.line_code, pp.last_save_id
  FROM public.property_profile pp
 WHERE pp.last_save_id IS NOT NULL
   AND NOT EXISTS (
     SELECT 1 FROM public.audit_event ae
      WHERE ae.run_id = pp.run_id AND ae.event_type='property_profile_recorded'
        AND ae.payload->>'save_id' = pp.last_save_id::text
   );


-- ============================================================================
-- 実測記録（実HTTP・実JWT、2026-07-31、agency a0000000-...-001 のテスト用
-- run 11111111-1111-1111-1111-111111111111（customer_type='individual'）を使用）:
--
-- 1. 正しいagencyのactive operatorが、賃貸だが借家人賠償・個人賠償が
--    未回答の個人プロファイルを保存
--    -> 成功。property_profile.last_save_id と audit_event.payload.save_id が
--       一致することを確認。payload.complete=false（isPropertyProfileComplete()
--       のSQL移植どおり、賃貸で両項目未回答のため不完了と正しく再導出）。
--
-- 2. 同一operatorが、借家人賠償・個人賠償の両方を回答した状態で再保存
--    （同一run_id・line_codeのためON CONFLICTでUPDATE経路を通る）
--    -> 成功。payload.complete=true（正しく完了と再導出）。
--
-- 3. 別agencyのoperator（agency 00000000）が、agency a0000000のrunに対して
--    保存を試行
--    -> 拒否（P0001, "権限がありません（他代理店のrun）"）。
--
-- 4. pure anonがsave_property_profileを直接呼ぶ
--    -> 拒否（42501 permission denied for function）。EXECUTE権限自体が
--       ないことを実行レベルで確認。
--
-- 5. 正しいagencyのactive operatorが、関数を経由せずproperty_profileへの
--    直接INSERTを試行（Data API経由）
--    -> 拒否（42501 permission denied for table）。関数迂回での直接書込みが
--       物理的に不可能であることを実行レベルで確認（田島様ご指摘の核心
--       「保存されるがaudit_eventが存在しない状態」を作れないことの証跡）。
--
-- テスト完了後、テスト用runに残ったproperty_profile行・audit_event
--（property_profile_recorded）はすべて削除済み（実測後の状態はテスト前と同一）。
-- ============================================================================
