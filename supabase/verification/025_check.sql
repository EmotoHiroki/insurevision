-- ============================================================================
-- 025_check.sql
--
-- migration 025（csv_import_session のagencyスコープ化）の検証。
-- DDLを一切含まない。025適用後に本ファイルを実行して状態を確認する。
-- ============================================================================
DO $$
DECLARE
    v_policy_count integer;
    v_old_exists   boolean;
    v_uses_gmai    boolean;
    v_has_check    boolean;
BEGIN
    SELECT count(*) INTO v_policy_count
      FROM pg_policies WHERE schemaname='public' AND tablename='csv_import_session';
    IF v_policy_count <> 1 THEN
        RAISE EXCEPTION '025 verify failed: expected exactly 1 policy on csv_import_session, found %', v_policy_count;
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname='public' AND tablename='csv_import_session'
           AND policyname='csv_import_session_agency_policy'
    ) INTO v_old_exists;
    IF v_old_exists THEN
        RAISE EXCEPTION '025 verify failed: old policy csv_import_session_agency_policy still exists';
    END IF;

    SELECT (qual LIKE '%get_my_agency_id%'), (with_check LIKE '%get_my_agency_id%')
      INTO v_uses_gmai, v_has_check
      FROM pg_policies
     WHERE schemaname='public' AND tablename='csv_import_session'
       AND policyname='csv_import_session_own_agency';

    IF NOT v_uses_gmai THEN
        RAISE EXCEPTION '025 verify failed: new policy does not reference get_my_agency_id() in USING';
    END IF;
    IF NOT v_has_check THEN
        RAISE EXCEPTION '025 verify failed: new policy has no WITH CHECK referencing get_my_agency_id()';
    END IF;

    RAISE NOTICE '025 verify passed: csv_import_session now uses get_my_agency_id() in both USING and WITH CHECK';
END;
$$;

-- ============================================================================
-- 横展開（田島様2026-07-30ご指摘C-12への対応）:
-- 「get_my_agency_id() を使わないagencyスコープ・ポリシーが他に残っていないか」
-- を、public スキーマの全ポリシーに対して走査する。
-- ============================================================================
DO $$
DECLARE
    v_bad text;
BEGIN
    -- operator/agency_id を参照しているのに get_my_agency_id() を使っていない
    -- ポリシーを検出する（=同型の不備が他に残っていないかの全件確認）。
    SELECT string_agg(format('%s.%s (cmd=%s)', tablename, policyname, cmd), ', ')
      INTO v_bad
      FROM pg_policies
     WHERE schemaname = 'public'
       AND (
             coalesce(qual,'') ~* 'agency_id|operator'
          OR coalesce(with_check,'') ~* 'agency_id|operator'
           )
       AND coalesce(qual,'') !~* 'get_my_agency_id'
       AND coalesce(with_check,'') !~* 'get_my_agency_id';

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION '025 sweep failed: policies referencing agency_id/operator without get_my_agency_id() -> %', v_bad;
    END IF;

    RAISE NOTICE '025 sweep passed: no remaining policy references agency_id/operator without going through get_my_agency_id()';
END;
$$;
