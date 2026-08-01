-- ============================================================================
-- 037_b1_ms1_save_property_profile_hardening.sql
--
-- 背景（田島様2026-08-01ご指摘A・015再確認への対応）:
--   015の save_property_profile を再確認したところ、他の全SECURITY DEFINER
--   関数（exclude_candidate・update_candidate_coverage_status・finalize_run
--   ・issue_smartphone_confirm_token等）が一貫して行っている
--   `AND is_active = true` の検査が抜けていた。すなわち無効化
--   （退職・異動等）されたoperatorのアカウントでも、そのauth_user_idが
--   残っている限り本関数を呼び出せる状態だった。
--
--   また、他の書込み関数（024・028・030・032）が一貫して行っている
--   run.finalized_at IS NOT NULL の確定後拒否チェックも存在せず、
--   確定済みrunに対しても物件プロファイルを書き換えられる状態だった。
--
--   line_code については既存の外部キー制約（property_profile_line_code_fkey）
--   により insurance_line に存在しないコードは元々拒否される。
--   ownership_type（個人・賃貸以外の値）についても、想定外の文字列が
--   入った場合はisPropertyProfileComplete相当の完了判定でfalse扱いに
--   なるのみで保存自体は拒否されない。これは「不正な値の拒否」ではなく
--   「未完了として扱う」設計であり、他の入力欄（building_structure等の
--   自由記述欄）と同様に、値の形式自体は本関数の責務外としてきた。
--   本migrationでは、least-privilegeの原則に基づき、is_active検査・
--   確定後Freezeの2点のみを追加し、それ以外の設計方針は変更しない。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.save_property_profile(
    p_run_id uuid,
    p_line_code text,
    p_municipality_code text,
    p_attributes jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_operator_id   uuid;
    v_agency_id     uuid;
    v_run_agency    uuid;
    v_run_status    text;
    v_customer_type text;
    v_flood_grade   int;
    v_complete      boolean;
    v_save_id       uuid := gen_random_uuid();
BEGIN
    -- 呼出ユーザーの operator・agency を auth.uid() から導出（クライアント値を信用しない）。
    -- 他の全SECURITY DEFINER関数と同一のis_active検査を追加（田島様2026-08-01ご指摘）。
    SELECT id, agency_id INTO v_operator_id, v_agency_id
    FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 呼出ユーザーが特定できません';
    END IF;

    SELECT agency_id, customer_type, run_status INTO v_run_agency, v_customer_type, v_run_status
    FROM public.run WHERE id = p_run_id;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 対象runが存在しません';
    END IF;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'save_property_profile: 権限がありません（他代理店のrun）';
    END IF;

    -- 確定後Freeze（田島様2026-08-01ご指摘。他の書込み関数と同一の検査を追加）
    IF v_run_status = 'finalized' THEN
        RAISE EXCEPTION 'save_property_profile: run is already finalized, property profile can no longer be modified';
    END IF;

    SELECT flood_grade INTO v_flood_grade FROM public.flood_zone_master WHERE municipality_code = p_municipality_code;

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

    INSERT INTO public.property_profile (run_id, line_code, municipality_code, attributes, last_save_id, updated_at)
    VALUES (p_run_id, p_line_code, p_municipality_code, p_attributes, v_save_id, now())
    ON CONFLICT (run_id, line_code) DO UPDATE
        SET municipality_code = EXCLUDED.municipality_code,
            attributes        = EXCLUDED.attributes,
            last_save_id      = EXCLUDED.last_save_id,
            updated_at        = now();

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

REVOKE EXECUTE ON FUNCTION public.save_property_profile(uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.save_property_profile(uuid, text, text, jsonb) TO authenticated;
