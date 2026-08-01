-- ============================================================================
-- 043_b1_ms1_compare_presented_and_smartphone_field_lockdown.sql
--
-- 背景（042実装中に発見した新規の穴。田島様への報告なしで発見・是正）:
--
-- 042で`record_compare_presented`関数を新設したが、実際のアプリコード
-- （`src/app/run/[id]/page.tsx`の`handleStartPresenting`）は、この関数を
-- 経由せず、`run.compare_presented_at`への直接UPDATEと`audit_event`への
-- 直接INSERTを行っていた。列権限を確認したところ、`authenticated`ロールは
-- `run`テーブルのほぼ全列に対してテーブル全体のUPDATE権限を持っており、
-- `compare_presented_at`も含め、036で導入したFreezeロックダウン
-- トリガー（`enforce_run_finalize_lockdown`）が保護する対象
-- （run_status='finalized'関連の列のみ）に含まれていなかった。
--
-- 同様に、`recruiter_smartphone_confirmed_at`・
-- `customer_smartphone_confirmed_at`・`smartphone_conf_status`も、
-- 040/041で専任のSECURITY DEFINER関数を用意したにもかかわらず、直接
-- UPDATEで書き換え可能なままだった（036のトリガーは finalize 系列のみ
-- 保護しており、この3列は対象外だった）。
--
-- 田島様が当初ご依頼の「個別の関数にガードを追加する形ではなく、確定
-- 状態の判定基準と全書込み経路の設計としてご提示いただくのが確実」
-- という方針に従い、既存の`enforce_run_finalize_lockdown`トリガーを
-- 拡張し、専任関数を持つすべての列を一箇所で保護する形にする
-- （個別トリガーを増殖させない）。
--
-- 【対応】
--   1. `enforce_run_finalize_lockdown`を拡張し、`authenticated`による
--      直接UPDATEから以下も保護する:
--      - compare_presented_at（record_compare_presented経由のみ）
--      - recruiter_smartphone_confirmed_at / customer_smartphone_confirmed_at
--        / smartphone_conf_status（confirm_smartphone /
--        record_smartphone_manual_confirmation経由のみ）
--   2. `enforce_audit_event_protected_types`の保護対象イベント一覧に
--      `compare_presented`を追加。
--   3. アプリ側: `src/app/run/[id]/page.tsx`の`handleStartPresenting`を
--      `record_compare_presented` RPC呼出しへ変更（本migrationと同一
--      コミットで反映、別途デプロイ）。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
BEGIN
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized' THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    IF current_user = 'authenticated' THEN
        IF (NEW.run_status = 'finalized' AND OLD.run_status IS DISTINCT FROM 'finalized')
           OR NEW.finalized_at   IS DISTINCT FROM OLD.finalized_at
           OR NEW.finalized_by   IS DISTINCT FROM OLD.finalized_by
           OR NEW.pdf_object_key IS DISTINCT FROM OLD.pdf_object_key
           OR NEW.pdf_sha256     IS DISTINCT FROM OLD.pdf_sha256
           OR NEW.export_status  IS DISTINCT FROM OLD.export_status
        THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
        END IF;

        IF NEW.compare_presented_at IS DISTINCT FROM OLD.compare_presented_at THEN
            RAISE EXCEPTION 'run: compare_presented_at can only be modified via record_compare_presented() (run %)', OLD.id;
        END IF;

        IF NEW.recruiter_smartphone_confirmed_at IS DISTINCT FROM OLD.recruiter_smartphone_confirmed_at
           OR NEW.customer_smartphone_confirmed_at IS DISTINCT FROM OLD.customer_smartphone_confirmed_at
           OR NEW.smartphone_conf_status IS DISTINCT FROM OLD.smartphone_conf_status
        THEN
            RAISE EXCEPTION 'run: smartphone confirmation fields can only be modified via confirm_smartphone() or record_smartphone_manual_confirmation() (run %)', OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_audit_event_protected_types()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
BEGIN
    IF current_user = 'authenticated' AND NEW.event_type IN (
        'run_finalized', 'consent_comparison_result',
        'recruiter_smartphone_confirmed', 'customer_smartphone_confirmed',
        'property_profile_recorded', 'candidate_coverage_status_updated',
        'exclusion_reason_recorded', 'exclusion_reason_coded',
        'redundancy_resolution_recorded', 'insurer_list_presented',
        'compare_presented'
    ) THEN
        RAISE EXCEPTION 'audit_event: event_type "%" can only be recorded via its dedicated function, not by direct insert', NEW.event_type;
    END IF;
    RETURN NEW;
END;
$$;
