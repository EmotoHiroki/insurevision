-- =============================================
-- Phase2-b-1 b1-MS1 是正 第5段階: property_profile保存とaudit_event記録の一体化
-- =============================================
-- 田島様2026-07-21合意の第5段階。区分A（b1-MS1固有）。
-- 【本ファイルの状態】本番へは未適用。第5段階のご確認・ご承認後に適用する。
--
-- 【現状】アプリは property_profile の upsert と audit_event の insert を
--   クライアントから2回の独立呼出で実行しており、単一トランザクションでない。
--   証跡記録だけ失敗すると「物件情報のみ更新・証跡なし」の状態が残り得る。
--   また payload をクライアントから任意受領しており、実保存内容と不一致な証跡を
--   残せる余地がある。
--
-- 【方針（田島様 pt6/pt8）】
--   1. 保存＋証跡を1つのSECURITY INVOKER関数へ集約し単一トランザクション化。
--      SECURITY INVOKER のため既存RLS（第1段階の operator_id 本人性検査を含む）が
--      そのまま評価され、代理店分離が維持される。
--   2. operator_id はクライアントから受けず auth.uid() から導出。
--   3. 証跡の主要項目（municipality_code / flood_grade / customer_type / operator_id）は
--      関数内で実データから生成し、クライアント値で上書きさせない（真正性）。
--   4. 各保存にDB生成の更新ID（last_save_id）を付与し、property_profile と
--      audit_event.payload の双方に保持して1対1で対応付ける。

-- 更新IDの保持列（property_profile 側）
ALTER TABLE property_profile ADD COLUMN IF NOT EXISTS last_save_id uuid;

CREATE OR REPLACE FUNCTION public.save_property_profile(
    p_run_id uuid,
    p_line_code text,
    p_municipality_code text,
    p_attributes jsonb,
    p_complete boolean
)
RETURNS uuid                       -- 生成した save_id を返す
LANGUAGE plpgsql
SECURITY INVOKER                   -- 呼出ユーザー権限。既存RLSをそのまま適用する
SET search_path = public
AS $$
DECLARE
    v_operator_id  uuid;
    v_customer_type text;
    v_flood_grade  int;
    v_save_id      uuid := gen_random_uuid();
BEGIN
    -- 呼出ユーザーの operator を auth.uid() から導出（クライアント値を信用しない）
    SELECT id INTO v_operator_id FROM operator WHERE auth_user_id = auth.uid();
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 呼出ユーザーが特定できません';
    END IF;

    -- 証跡の主要項目は実データから生成（改ざん防止）
    SELECT customer_type INTO v_customer_type FROM run WHERE id = p_run_id;
    SELECT flood_grade INTO v_flood_grade FROM flood_zone_master WHERE municipality_code = p_municipality_code;

    -- (1) property_profile を upsert（run_id + line_code でユニーク）。last_save_id を付与
    INSERT INTO property_profile (run_id, line_code, municipality_code, attributes, last_save_id, updated_at)
    VALUES (p_run_id, p_line_code, p_municipality_code, p_attributes, v_save_id, now())
    ON CONFLICT (run_id, line_code) DO UPDATE
        SET municipality_code = EXCLUDED.municipality_code,
            attributes        = EXCLUDED.attributes,
            last_save_id      = EXCLUDED.last_save_id,
            updated_at        = now();

    -- (2) 同一トランザクションで audit_event を記録。operator_id は導出値、
    --     payload は実データから生成し、save_id を保持（property_profile と対応付け）
    INSERT INTO audit_event (run_id, event_type, operator_id, payload)
    VALUES (
        p_run_id,
        'property_profile_recorded',
        v_operator_id,
        jsonb_build_object(
            'line_code', p_line_code,
            'customer_type', v_customer_type,
            'municipality_code', p_municipality_code,
            'flood_grade', v_flood_grade,
            'complete', p_complete,
            'save_id', v_save_id
        )
    );

    RETURN v_save_id;
END;
$$;

-- authenticated からのみ実行可能とする（anon/PUBLIC には付与しない）
REVOKE EXECUTE ON FUNCTION public.save_property_profile(uuid, text, text, jsonb, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.save_property_profile(uuid, text, text, jsonb, boolean) TO authenticated;

-- 【検証用】各 property_profile の last_save_id に対応する audit_event が存在するか:
--   SELECT pp.run_id FROM property_profile pp
--   WHERE pp.last_save_id IS NOT NULL AND NOT EXISTS (
--     SELECT 1 FROM audit_event ae
--     WHERE ae.run_id = pp.run_id AND ae.event_type='property_profile_recorded'
--       AND ae.payload->>'save_id' = pp.last_save_id::text);
