-- =============================================
-- Phase2-b-1 b1-MS1 是正 第5段階: property_profile保存とaudit_event記録の一体化（再設計版）
-- =============================================
-- 田島様2026-07-21合意の第5段階。区分A（b1-MS1固有）。
-- 【本ファイルの状態】本番へは未適用。田島様2026-07-24・2026-07-25ご指摘を反映した再設計版。
--   別紙「b1-MS1 第5段階 save_property_profile設計案」でのご確認・ご承認後に適用する。
--
-- 【改訂（2026-07-24・再設計）】
-- 初版は save_property_profile を SECURITY INVOKER とし、既存RLS（agencyスコープ）に
-- 委ねる方式としていた。田島様より次のご指摘をいただいた:
--   「authenticatedユーザーが property_profile への直接INSERT/UPDATE権限を保持したままでは、
--    本関数を経由せず直接書込みが可能であり、保存はされるが対応する audit_event が
--    存在しない状態を作れてしまう。SECURITY INVOKERのまま権限を剥奪すると関数自身も
--    書込みできなくなるため、権限付き関数やトリガー等を含め、既存RLSと整合する案を
--    ご提示いただきたい。」
-- ご指摘のとおり、権限剥奪とSECURITY INVOKER維持は両立しない。以下のとおり再設計する。
--
-- 【改訂（2026-07-25）】
--   1. p_complete引数を廃止。クライアント計算値をそのまま信用していたため、RPC直接呼出で
--      任意にtrueを渡せる状態だった。p_attributesから関数内で完了状態を再導出する
--      （下記【完了判定のSQL移植について】参照）。
--   2. search_path を空文字列へ変更し、全参照をスキーマ修飾（第3・第4段階と同方針）。
--
-- 【再設計方針】
--   1. property_profile への INSERT/UPDATE/DELETE 権限を authenticated から剥奪する
--      （SELECTは維持。既存RLSポリシー property_profile_own_agency による自代理店閲覧は
--      従来どおり継続）。これにより直接のテーブル書込み経路そのものを塞ぐ。
--   2. save_property_profile を SECURITY DEFINER へ変更し、関数所有者（テーブル所有者）
--      権限で書込みを行う。SECURITY DEFINER は RLS を完全に迂回するため、関数内で
--      既存RLSと同等のチェック（対象runが呼出userのagencyに属すること）を手動で実施し、
--      RLSと整合する認可を維持する（田島様「既存RLSと整合する案」に対応）。
--   3. search_path を空にして全参照をスキーマ修飾し、PUBLIC/anon から EXECUTE を剥奪、
--      authenticated にのみ許可する（第3段階 finalize_run 設計案と同一のSECURITY DEFINER衛生方針）。
--      【search_path='' と組込み関数について】search_path が空でも pg_catalog は常に暗黙的に
--      検索されるため、now()・jsonb_build_object()・gen_random_uuid() 等は修飾なしで安全に
--      解決される。特に gen_random_uuid() は本番DBに pg_catalog（PG13以降の組込み）と
--      extensions（pgcrypto）の両方に存在するが（2026-07-26実測）、pg_catalog が優先される
--      ため意図した組込み版が呼ばれる。テーブル・自作関数のみ public. 修飾が必須。
--   4. operator_id・証跡主要項目の関数内導出（初版から維持）、last_save_id による
--      property_profile-audit_event の1対1対応付け（初版から維持）。
--   5. 完了状態（complete）はクライアントの申告を信用せず、p_attributesから関数内で再導出する。
--
-- 【完了判定のSQL移植について】
--   下記の完了判定は src/lib/insurance/property.ts の isPropertyProfileComplete() と
--   同一の条件をSQLへ移植したものです。TypeScript側のロジックを変更した場合は、
--   本関数（save_property_profile）の完了判定も同時に更新する必要があります。
--
-- 【この設計で塞がる経路・塞がらない経路】
--   - authenticated による property_profile への直接 INSERT/UPDATE/DELETE: 塞がる（権限剥奪）。
--   - save_property_profile 経由の保存: 従来どおり可能（SECURITY DEFINER・関数内でagency照合）。
--   - service_role・postgres からの直接操作: 対象外（アプリはservice_roleを使用しない前提。
--     RLS設計全体の前提と同じ）。
--
-- 【アプリ側の変更（別紙§3参照）】
--   `src/app/run/[id]/property/page.tsx` の save() を、現行の
--   `supabase.from('property_profile').upsert(...)` ＋ 別呼出の audit_event insert から、
--   単一の `supabase.rpc('save_property_profile', {...})` 呼出へ置き換える。p_completeは
--   廃止したため送信不要。
--   【適用順序】権限剥奪後は旧アプリコード（直接upsert）が失敗するため、真に同時の反映は
--   できない。関数追加→アプリ切替→直接権限剥奪の順に分割して適用する
--   （第3段階finalize_run設計案§12と同方針）。

-- 更新IDの保持列（property_profile 側）
ALTER TABLE property_profile ADD COLUMN IF NOT EXISTS last_save_id uuid;

-- authenticated からの property_profile 直接書込み権限を剥奪（SELECTは維持）
REVOKE INSERT, UPDATE, DELETE ON TABLE property_profile FROM authenticated;

CREATE OR REPLACE FUNCTION public.save_property_profile(
    p_run_id uuid,
    p_line_code text,
    p_municipality_code text,
    p_attributes jsonb
)
RETURNS uuid                       -- 生成した save_id を返す
LANGUAGE plpgsql
SECURITY DEFINER                   -- 権限剥奪後も関数自身は書込み可能にするため。
                                    -- RLSを迂回する分、関数内でRLS相当の認可チェックを
                                    -- 手動実施する（下記）。
SET search_path = ''               -- 空にして全参照をスキーマ修飾（2026-07-25改訂）
AS $$
DECLARE
    v_operator_id   uuid;
    v_agency_id     uuid;
    v_run_agency    uuid;
    v_customer_type text;
    v_flood_grade   int;
    v_complete      boolean;
    v_save_id       uuid := gen_random_uuid();
BEGIN
    -- 呼出ユーザーの operator・agency を auth.uid() から導出（クライアント値を信用しない）
    SELECT id, agency_id INTO v_operator_id, v_agency_id
    FROM public.operator WHERE auth_user_id = auth.uid();
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 呼出ユーザーが特定できません';
    END IF;

    -- RLS相当の認可チェック: 対象runが呼出userのagencyに属すること
    -- （SECURITY DEFINERはRLSを迂回するため、本関数内で明示的に検査する）
    SELECT agency_id, customer_type INTO v_run_agency, v_customer_type
    FROM public.run WHERE id = p_run_id;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 対象runが存在しません';
    END IF;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'save_property_profile: 権限がありません（他代理店のrun）';
    END IF;

    -- 証跡の主要項目は実データから生成（改ざん防止）
    SELECT flood_grade INTO v_flood_grade FROM public.flood_zone_master WHERE municipality_code = p_municipality_code;

    -- 完了状態はクライアントの申告を信用せず、p_attributesから再導出する
    -- （isPropertyProfileComplete()のSQL移植。2026-07-25改訂）
    IF v_customer_type = 'individual' THEN
        v_complete :=
            (p_attributes->>'ownership_type') IS NOT NULL
            AND (p_attributes->>'has_household_goods') IS NOT NULL
            AND (p_attributes->>'earthquake_insurance') IS NOT NULL
            AND (
                (p_attributes->>'ownership_type') IS DISTINCT FROM 'rental'
                OR (
                    (p_attributes->>'renter_liability') IS NOT NULL
                    AND (p_attributes->>'personal_liability') IS NOT NULL
                )
            );
    ELSIF v_customer_type = 'corporate' THEN
        v_complete :=
            (p_attributes->>'property_count') IS NOT NULL
            AND (p_attributes->>'property_count')::int >= 1
            AND (
                (p_attributes->>'property_count')::int = 1
                OR (
                    (p_attributes->>'schedule_reference')::boolean IS TRUE
                    AND (p_attributes->>'schedule_acknowledged')::boolean IS TRUE
                )
            );
    ELSE
        v_complete := false;
    END IF;

    -- (1) property_profile を upsert（run_id + line_code でユニーク）。last_save_id を付与
    INSERT INTO public.property_profile (run_id, line_code, municipality_code, attributes, last_save_id, updated_at)
    VALUES (p_run_id, p_line_code, p_municipality_code, p_attributes, v_save_id, now())
    ON CONFLICT (run_id, line_code) DO UPDATE
        SET municipality_code = EXCLUDED.municipality_code,
            attributes        = EXCLUDED.attributes,
            last_save_id      = EXCLUDED.last_save_id,
            updated_at        = now();

    -- (2) 同一トランザクションで audit_event を記録。operator_id は導出値、
    --     payload は実データから生成し、save_id を保持（property_profile と対応付け）
    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (
        p_run_id,
        'property_profile_recorded',
        v_operator_id,
        jsonb_build_object(
            'line_code', p_line_code,
            'customer_type', v_customer_type,
            'municipality_code', p_municipality_code,
            'flood_grade', v_flood_grade,
            'complete', v_complete,
            'save_id', v_save_id
        )
    );

    RETURN v_save_id;
END;
$$;

-- authenticated からのみ実行可能とする（anon/PUBLIC には付与しない）
REVOKE EXECUTE ON FUNCTION public.save_property_profile(uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.save_property_profile(uuid, text, text, jsonb) TO authenticated;

-- 【検証用】直接書込みが拒否されることの確認（ロールバック付きトランザクションで実施予定）:
--   BEGIN; SET LOCAL ROLE authenticated;
--   SELECT set_config('request.jwt.claim.sub','<uuid>',true);
--   INSERT INTO property_profile (run_id, line_code, attributes) VALUES ('<run_id>','fire','{}');
--   -- 期待結果: ERROR: permission denied for table property_profile
--   ROLLBACK;
--
-- 【検証用】各 property_profile の last_save_id に対応する audit_event が存在するか:
--   SELECT pp.run_id FROM property_profile pp
--   WHERE pp.last_save_id IS NOT NULL AND NOT EXISTS (
--     SELECT 1 FROM audit_event ae
--     WHERE ae.run_id = pp.run_id AND ae.event_type='property_profile_recorded'
--       AND ae.payload->>'save_id' = pp.last_save_id::text);
--
-- 【検証用】完了判定の再導出が正しいか（isPropertyProfileComplete()との一致確認）:
--   代表シナリオ（個人: 持家・家財あり・地震保険あり、個人: 賃貸で借家人賠償/個人賠償が未回答、
--   法人: 単一物件、法人: 複数物件でschedule_acknowledged未確認 等）を実行し、
--   audit_event.payload->>'complete' が期待値と一致することを確認する。
