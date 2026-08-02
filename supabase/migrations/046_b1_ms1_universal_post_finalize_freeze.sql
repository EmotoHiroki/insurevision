-- ============================================================================
-- 046_b1_ms1_universal_post_finalize_freeze.sql
--
-- 【緊急・自己発見の回帰】036適用以降、確定済みrunの「アーカイブ」
-- ボタン（`src/app/run/[id]/page.tsx`、run_status='finalized'の時のみ
-- 表示）が完全に機能しなくなっていたことを、本migrationの検証中に
-- 実機で発見した。原因は2点:
--   1. 036の`enforce_run_finalize_lockdown`が「finalizedから離脱する
--      遷移」を一律で拒否しており、'finalized'→'archived'という
--      正規の運用上の遷移も「離脱」とみなして拒否していた。
--   2. 036のCHECK制約`run_finalized_state_consistency`
--      `(run_status = 'finalized') = (finalized_at IS NOT NULL)`は、
--      run_status='archived'の場合にfinalized_atがNOT NULLのままだと
--      矛盾として扱われ、UPDATE自体が制約違反で失敗する
--      （run_status='finalized'でなくなった時点で左辺がfalseになるが、
--      finalized_atは削除されないため右辺はtrueのまま）。
-- 実測（実HTTP・実SQL、対象runは元の状態へ復元済み）で両方の失敗を
-- 確認した。本migrationでこの2点をあわせて是正する
-- （finalized_atは「過去に確定した事実の記録」としてarchived後も
-- 保持すべきであり、削除する設計変更はしない）。
--
-- ---
--
-- 背景（田島様2026-08-01ご指摘Jの残タスク実施中に発見。実測で確認済み）:
--
--   `intent_confirmation`・`csv_import_session`は、確定済み（finalized）の
--   runに対しても直接のData API経由でINSERT/UPDATEが成立してしまう
--   ことを、確定済みの本番run（テスト用）に対する実HTTPで確認した
--   （いずれもHTTP 201で成功）。両テーブルのRLSポリシーは代理店スコープ
--   のみを見ており、run_statusを一切見ていない。
--
--   これをきっかけに全テーブルのトリガーを棚卸ししたところ、同型の
--   問題が`candidate`・`snapshot`・`property_profile`にも存在することが
--   判明した。これらのテーブルへの書込みは`exclude_candidate`・
--   `update_candidate_coverage_status`・`update_snapshot_redundancy_
--   decisions`・`update_snapshot_resolution_memo`・`save_property_profile`
--   というSECURITY DEFINER関数を経由する限りは確定後凍結が効くが、
--   これらのテーブルへの**直接のUPDATE/INSERT**（Data API経由の生の
--   PATCH/POST）はRLSの代理店スコープチェックしか通らず、run_statusを
--   一切見ていないため、確定済みrunに対しても素通りしてしまう。
--
--   また`run`テーブル自身についても、036/043/045で個別の列
--   （finalize系・compare_presented_at・smartphone確認系・プラン選択系）
--   を都度ブロックリスト式で追加してきたが、`delivery_status`・
--   `electronic_consent_*`・`paper_confirmation_*`・`important_matters_*`・
--   `priority_factors`・`comparison_scope`等、確定後は本来変更されるべき
--   ではない列がまだ多数保護対象外であることが判明した（アプリ側の
--   `run_status==='draft'`チェックのみに依存しており、DB側の強制がない）。
--
-- 【対応方針の転換】
--   個別列を都度ブロックリストに追加するのではなく、「runがfinalized
--   状態になった後は、authenticatedによるrun行への直接書込みを完全に
--   禁止する」という単純で堅牢なルールに一本化する。SECURITY DEFINER
--   関数はすべて実行中current_userがpostgresへ切り替わるため、この
--   ルールの影響を受けない。
--
--   あわせて、run_idを持つ子テーブル（candidate・snapshot・
--   property_profile・intent_confirmation・csv_import_session）に
--   共通のBEFORE INSERT/UPDATEトリガーを追加し、親runがfinalizedの
--   場合はauthenticatedによる直接の書込みを一律で拒否する。
-- ============================================================================

-- ── run: 個別列のブロックリストを「finalized後は全面禁止」へ一本化 ─────────
-- 唯一の例外: finalized → archived への遷移（run_statusのみの変更）は許可する
-- （`src/app/run/[id]/page.tsx`のアーカイブボタンが行う正規の操作）。
CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
    v_new_normalized public.run;
BEGIN
    -- 確定状態からの離脱（draft等への巻き戻し）は誰であっても禁止するが、
    -- archivedへの遷移は正規の運用として許可する
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized'
       AND NEW.run_status IS DISTINCT FROM 'archived'
    THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    IF current_user = 'authenticated' THEN
        -- 既に確定済みの行: archivedへの遷移（run_status列のみの変更）だけを許可し、
        -- それ以外の直接書込みは一切禁止する
        IF OLD.run_status = 'finalized' THEN
            IF NEW.run_status = 'archived' THEN
                v_new_normalized := NEW;
                v_new_normalized.run_status := OLD.run_status;
                v_new_normalized.updated_at := OLD.updated_at;
                IF v_new_normalized IS DISTINCT FROM OLD THEN
                    RAISE EXCEPTION 'run: only run_status may change when archiving a finalized run (run %)', OLD.id;
                END IF;
                RETURN NEW;
            END IF;
            RAISE EXCEPTION 'run: row is already finalized, no further direct modification permitted (run %)', OLD.id;
        END IF;

        -- 確定への遷移そのものの偽装を禁止（finalize_run()経由のみ許可）
        IF NEW.run_status = 'finalized' THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
        END IF;

        -- 確定前であっても、専任関数を持つ列は直接書込みを禁止
        -- （関数側の代理店確認・候補存在確認・冪等性チェック等を必ず経由させる）
        IF NEW.finalized_at   IS DISTINCT FROM OLD.finalized_at
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

        IF NEW.recommended_candidate_id IS DISTINCT FROM OLD.recommended_candidate_id
           OR NEW.decided_candidate_id IS DISTINCT FROM OLD.decided_candidate_id
           OR NEW.plan_diff_reason IS DISTINCT FROM OLD.plan_diff_reason
           OR NEW.plan_diff_reason_recorded_at IS DISTINCT FROM OLD.plan_diff_reason_recorded_at
        THEN
            RAISE EXCEPTION 'run: plan selection fields can only be modified via record_plan_selection() (run %)', OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- ── run_idを持つ子テーブル共通: 親runがfinalizedなら直接書込みを禁止 ───────
CREATE OR REPLACE FUNCTION public.enforce_parent_run_not_finalized()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
    v_run_status text;
BEGIN
    IF current_user <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    SELECT run_status INTO v_run_status FROM public.run WHERE id = NEW.run_id;
    IF v_run_status = 'finalized' THEN
        RAISE EXCEPTION '%: parent run is finalized, direct modification no longer permitted (run %)', TG_TABLE_NAME, NEW.run_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_candidate_parent_run_not_finalized
    BEFORE INSERT OR UPDATE ON public.candidate
    FOR EACH ROW EXECUTE FUNCTION public.enforce_parent_run_not_finalized();

CREATE TRIGGER trg_snapshot_parent_run_not_finalized
    BEFORE INSERT OR UPDATE ON public.snapshot
    FOR EACH ROW EXECUTE FUNCTION public.enforce_parent_run_not_finalized();

CREATE TRIGGER trg_property_profile_parent_run_not_finalized
    BEFORE INSERT OR UPDATE ON public.property_profile
    FOR EACH ROW EXECUTE FUNCTION public.enforce_parent_run_not_finalized();

CREATE TRIGGER trg_intent_confirmation_parent_run_not_finalized
    BEFORE INSERT OR UPDATE ON public.intent_confirmation
    FOR EACH ROW EXECUTE FUNCTION public.enforce_parent_run_not_finalized();

CREATE TRIGGER trg_csv_import_session_parent_run_not_finalized
    BEFORE INSERT OR UPDATE ON public.csv_import_session
    FOR EACH ROW EXECUTE FUNCTION public.enforce_parent_run_not_finalized();

-- ── CHECK制約の是正: archivedもfinalized_at必須の対象に含める ─────────────
-- 旧: (run_status = 'finalized') = (finalized_at IS NOT NULL)
--     → archived後もfinalized_atを保持する設計と矛盾し、アーカイブ操作
--       自体がCHECK制約違反で失敗していた（本migrationで実機確認）。
-- 新: run_statusの取り得る値は draft・finalized・archived・suspended・
--     post_record_pending の5種類（run_status本体のCHECK制約より）。
--     finalized・archivedはfinalized_atがNOT NULLであること、それ以外
--     （draft・suspended・post_record_pending）はNULLであることを要求する。
ALTER TABLE public.run DROP CONSTRAINT IF EXISTS run_finalized_state_consistency;
ALTER TABLE public.run ADD CONSTRAINT run_finalized_state_consistency
    CHECK (
        (run_status IN ('draft', 'suspended', 'post_record_pending') AND finalized_at IS NULL)
        OR (run_status IN ('finalized', 'archived') AND finalized_at IS NOT NULL)
    );
