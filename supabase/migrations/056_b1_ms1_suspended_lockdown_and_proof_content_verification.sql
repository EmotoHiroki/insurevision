-- ============================================================================
-- 056_b1_ms1_suspended_lockdown_and_proof_content_verification.sql
--
-- 田島様2026-08-05レビューでご指摘いただいた2件の未達を是正する。
--
-- 【是正1】suspended（保留中）の書込み制御が指示と逆になっていた
--   ご指示: 「suspendedは再開操作以外の書込み不可」。
--   実態: 画面側は `isEditable = draft || post_record_pending` として既に
--         suspendedを編集不可として扱っていたが、DB側の各RPCは
--         `run_status IN ('finalized','archived')` のみを拒否しており、
--         suspendedのrunに対して候補追加・除外・付帯状況変更・物件プロフィール
--         保存・子テーブル書込みがすべて通る状態だった。
--         画面のボタンが無効なだけで、RPCを直接呼べば書き換えられる
--         （＝画面のみで守られていてDBが守っていない）という、これまで
--         繰り返し是正してきたものと同型の欠陥である。
--   是正: 状態判定を「拒否リスト（finalized/archived）」から
--         「許可リスト（draft/post_record_pending）」へ統一する。
--         これにより suspended は今後、列挙漏れによって再び通ることがない。
--         `run`本体への直接UPDATEについても、suspended中は「再開操作
--         （run_status→draft かつ保留3列のクリアのみ）」以外を拒否する。
--         保留操作そのもの（draft→suspended）は従来どおり許可する。
--
-- 【是正2】Storage証跡のSHA-256検証が内容一致を保証していなかった
--   ご指摘: migration 054の検証は `storage.objects.user_metadata->>'sha256'`
--           と、RPC引数 `p_pdf_sha256` を突き合わせるだけだった。両方とも
--           同一の呼出し元が渡す値であるため、任意の内容をアップロードして
--           任意のハッシュをメタデータに付ければ検査を通過できる構造であり、
--           「保存された実ファイルの内容のSHA-256一致をサーバー側で保証する」
--           という要件を満たしていなかった。
--   是正: 証跡の本文（payload）自体を `public.run_proof` へ保存し、
--         SHA-256は **DB側で pgcrypto により算出** する（呼出し元が申告した
--         ハッシュ値は一切信用しない）。さらに、DB上のpayloadと
--         Storage上の実バイト列の同一性を、Storageサービスが実バイトから
--         書き込む `storage.objects.metadata`（`size`・`eTag`。呼出し元が
--         偽装できない領域。ユーザーが任意に設定できる `user_metadata` とは
--         別物）と突き合わせて検証する。
--
--   注記: Postgresから S3 上の実バイト列を直接読むことはできないため、
--         「DBが自ら算出したSHA-256」＋「Storageサービスが実バイトから
--         算出したサイズ・eTag(MD5)との一致」の二段で内容同一性を保証する。
--
-- 適用先: 本番 ytpaklotlgrbslshjggc / 検証 uwwrtrzhyjormwfyvmrg
-- ============================================================================

-- ── 是正2-a: 証跡本文の保管先 ───────────────────────────────────────────────
-- 直接の読み書きは一切許可しない（RLS有効・FORCE・ポリシー0件のdeny-all）。
-- 書込みは save_run_proof()、読取りは finalize_run() という
-- SECURITY DEFINER関数からのみ行う。
CREATE TABLE IF NOT EXISTS public.run_proof (
    run_id     uuid PRIMARY KEY REFERENCES public.run(id) ON DELETE CASCADE,
    object_key text        NOT NULL,
    payload    text        NOT NULL,
    sha256     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.run_proof ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.run_proof FORCE ROW LEVEL SECURITY;

REVOKE ALL ON public.run_proof FROM PUBLIC;
REVOKE ALL ON public.run_proof FROM anon;
REVOKE ALL ON public.run_proof FROM authenticated;

-- ── 是正2-b: 証跡本文の登録（SHA-256はDB側で算出する） ─────────────────────
CREATE OR REPLACE FUNCTION public.save_run_proof(
    p_run_id     uuid,
    p_object_key text,
    p_payload    text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
    v_sha         text;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'save_run_proof: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'save_run_proof: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'save_run_proof: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'save_run_proof: run is %, proof can no longer be registered', v_run_status;
    END IF;

    IF p_object_key IS NULL OR p_object_key NOT LIKE ('runs/' || p_run_id::text || '/%') THEN
        RAISE EXCEPTION 'save_run_proof: p_object_key does not belong to this run';
    END IF;
    IF p_payload IS NULL OR btrim(p_payload) = '' THEN
        RAISE EXCEPTION 'save_run_proof: p_payload is required';
    END IF;

    -- 呼出し元が申告したハッシュは受け取らない。DBが本文から算出する。
    v_sha := encode(extensions.digest(p_payload, 'sha256'), 'hex');

    INSERT INTO public.run_proof (run_id, object_key, payload, sha256, created_at, updated_at)
    VALUES (p_run_id, p_object_key, p_payload, v_sha, now(), now())
    ON CONFLICT (run_id) DO UPDATE
        SET object_key = EXCLUDED.object_key,
            payload    = EXCLUDED.payload,
            sha256     = EXCLUDED.sha256,
            updated_at = now();

    RETURN v_sha;
END;
$$;

REVOKE ALL ON FUNCTION public.save_run_proof(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_run_proof(uuid, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_run_proof(uuid, text, text) TO authenticated;

-- ── 是正1-a: 親run状態の判定を許可リストへ統一（子テーブル共通トリガー） ──
CREATE OR REPLACE FUNCTION public.enforce_parent_run_not_finalized()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
DECLARE
    v_run_status text;
BEGIN
    IF current_user <> 'authenticated' THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.run_id IS DISTINCT FROM OLD.run_id THEN
        RAISE EXCEPTION '%: run_id cannot be changed after creation (attempted % -> %)',
            TG_TABLE_NAME, OLD.run_id, NEW.run_id;
    END IF;

    -- 親run行を行ロックしてから状態を判定する（migration 055）。
    -- finalize_run() も同じ行を FOR UPDATE でロックするため、確定処理と
    -- 子行書込みが並行しても直列化され、確定後の書込みは成立しない。
    SELECT run_status INTO v_run_status
      FROM public.run WHERE id = NEW.run_id FOR UPDATE;

    -- 許可リスト方式（migration 056）。従来は finalized/archived のみを
    -- 拒否していたため suspended が素通りしていた。
    IF v_run_status IS NULL OR v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION '%: parent run is %, direct modification is not permitted (run %)',
            TG_TABLE_NAME, coalesce(v_run_status, 'missing'), NEW.run_id;
    END IF;

    RETURN NEW;
END;
$$;

-- ── 是正1-b: run本体の直接UPDATE制御にsuspendedを追加 ──────────────────────
CREATE OR REPLACE FUNCTION public.enforce_run_finalize_lockdown()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $$
DECLARE
    v_new_normalized public.run;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF current_user = 'authenticated' THEN
            IF NEW.run_status IS DISTINCT FROM 'draft' THEN
                RAISE EXCEPTION 'run: new rows must be created with run_status=''draft'' (attempted %)', NEW.run_status;
            END IF;
            IF NEW.finalized_at IS NOT NULL OR NEW.finalized_by IS NOT NULL
               OR NEW.pdf_object_key IS NOT NULL OR NEW.pdf_sha256 IS NOT NULL
               OR (NEW.export_status IS NOT NULL AND NEW.export_status <> 'pending')
            THEN
                RAISE EXCEPTION 'run: finalize-owned fields cannot be set on insert, only via finalize_run()';
            END IF;
            IF NEW.compare_presented_at IS NOT NULL THEN
                RAISE EXCEPTION 'run: compare_presented_at cannot be set on insert, only via record_compare_presented()';
            END IF;
            IF NEW.recruiter_smartphone_confirmed_at IS NOT NULL
               OR NEW.customer_smartphone_confirmed_at IS NOT NULL
            THEN
                RAISE EXCEPTION 'run: smartphone confirmation fields cannot be set on insert';
            END IF;
            IF NEW.recommended_candidate_id IS NOT NULL OR NEW.decided_candidate_id IS NOT NULL
               OR NEW.plan_diff_reason IS NOT NULL OR NEW.plan_diff_reason_recorded_at IS NOT NULL
            THEN
                RAISE EXCEPTION 'run: plan selection fields cannot be set on insert';
            END IF;
        END IF;
        RETURN NEW;
    END IF;

    -- TG_OP = 'UPDATE'
    IF OLD.run_status = 'finalized' AND NEW.run_status IS DISTINCT FROM 'finalized'
       AND NEW.run_status IS DISTINCT FROM 'archived'
    THEN
        RAISE EXCEPTION 'run: cannot transition out of finalized state (run %)', OLD.id;
    END IF;

    IF OLD.run_status = 'archived' AND NEW.run_status IS DISTINCT FROM 'archived' THEN
        RAISE EXCEPTION 'run: cannot transition out of archived state (run %)', OLD.id;
    END IF;

    IF current_user = 'authenticated' THEN
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

        IF OLD.run_status = 'archived' THEN
            RAISE EXCEPTION 'run: row is archived, no further direct modification permitted (run %)', OLD.id;
        END IF;

        -- migration 056: 保留中は「再開操作」以外を一切許可しない。
        -- 再開＝run_statusをdraftへ戻し、保留3列をクリアする操作のみ。
        IF OLD.run_status = 'suspended' THEN
            IF NEW.run_status = 'draft' THEN
                IF NEW.suspension_type IS NOT NULL
                   OR NEW.pending_note IS NOT NULL
                   OR NEW.suspended_at IS NOT NULL
                THEN
                    RAISE EXCEPTION 'run: resuming a suspended run must clear suspension_type, pending_note and suspended_at (run %)', OLD.id;
                END IF;
                v_new_normalized := NEW;
                v_new_normalized.run_status      := OLD.run_status;
                v_new_normalized.suspension_type := OLD.suspension_type;
                v_new_normalized.pending_note    := OLD.pending_note;
                v_new_normalized.suspended_at    := OLD.suspended_at;
                v_new_normalized.updated_at      := OLD.updated_at;
                IF v_new_normalized IS DISTINCT FROM OLD THEN
                    RAISE EXCEPTION 'run: only the resume operation may modify a suspended run (run %)', OLD.id;
                END IF;
                RETURN NEW;
            END IF;
            RAISE EXCEPTION 'run: row is suspended, only the resume operation is permitted (run %)', OLD.id;
        END IF;

        IF NEW.run_status = 'finalized' THEN
            RAISE EXCEPTION 'run: finalize-owned fields can only be modified via finalize_run() (run %)', OLD.id;
        END IF;

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

        IF NEW.electronic_consent_status      IS DISTINCT FROM OLD.electronic_consent_status
           OR NEW.electronic_consent_method    IS DISTINCT FROM OLD.electronic_consent_method
           OR NEW.electronic_consent_confirmed_at IS DISTINCT FROM OLD.electronic_consent_confirmed_at
           OR NEW.electronic_consent_operator_id  IS DISTINCT FROM OLD.electronic_consent_operator_id
        THEN
            RAISE EXCEPTION 'run: electronic consent fields can only be modified via record_electronic_consent() (run %)', OLD.id;
        END IF;

        IF NEW.paper_confirmation_status IS DISTINCT FROM OLD.paper_confirmation_status
           OR NEW.paper_confirmation_completed_at IS DISTINCT FROM OLD.paper_confirmation_completed_at
        THEN
            RAISE EXCEPTION 'run: paper confirmation fields can only be modified via record_paper_confirmation() (run %)', OLD.id;
        END IF;

        IF NEW.important_matters_delivered IS DISTINCT FROM OLD.important_matters_delivered
           OR NEW.important_matters_delivered_at IS DISTINCT FROM OLD.important_matters_delivered_at
           OR NEW.important_matters_delivery_method IS DISTINCT FROM OLD.important_matters_delivery_method
        THEN
            RAISE EXCEPTION 'run: important matters delivery fields can only be modified via record_important_matters_delivery() (run %)', OLD.id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

-- ── 是正1-c: 各RPCの状態判定を許可リストへ統一 ─────────────────────────────

CREATE OR REPLACE FUNCTION public.add_candidate(
    p_run_id uuid,
    p_insurer_name text DEFAULT ''::text,
    p_product_name text DEFAULT NULL::text,
    p_annual_premium integer DEFAULT NULL::integer,
    p_role text DEFAULT NULL::text
)
RETURNS public.candidate
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id       uuid;
    v_run_agency        uuid;
    v_run_status        text;
    v_compare_presented timestamptz;
    v_next_slot         int;
    v_candidate         public.candidate;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'add_candidate: no active operator for the calling session';
    END IF;

    IF p_role IS NULL AND btrim(coalesce(p_insurer_name, '')) = '' THEN
        RAISE EXCEPTION 'add_candidate: insurer_name is required';
    END IF;

    SELECT agency_id, run_status, compare_presented_at
      INTO v_run_agency, v_run_status, v_compare_presented
      FROM public.run WHERE id = p_run_id FOR UPDATE;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'add_candidate: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'add_candidate: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'add_candidate: run is %, candidates can no longer be added', v_run_status;
    END IF;

    SELECT coalesce(max(slot_no), 0) + 1 INTO v_next_slot
      FROM public.candidate WHERE run_id = p_run_id;

    INSERT INTO public.candidate (run_id, slot_no, insurer_name, product_name, annual_premium, role, status)
    VALUES (p_run_id, v_next_slot, coalesce(p_insurer_name, ''), p_product_name, p_annual_premium, p_role, 'active')
    RETURNING * INTO v_candidate;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'candidate_added', v_operator_id,
            jsonb_build_object('candidate_id', v_candidate.id, 'slot_no', v_next_slot, 'role', p_role));

    IF v_compare_presented IS NOT NULL THEN
        UPDATE public.run SET compare_presented_at = NULL WHERE id = p_run_id;
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'compare_presented', v_operator_id,
                jsonb_build_object(
                    'invalidated', true,
                    'invalidated_reason', 'candidate_added_after_presentation',
                    'candidate_id', v_candidate.id,
                    'previous_presented_at', v_compare_presented
                ));
    END IF;

    RETURN v_candidate;
END;
$$;

CREATE OR REPLACE FUNCTION public.exclude_candidate(
    p_candidate_id uuid,
    p_reason_code text DEFAULT NULL::text,
    p_reason_text text DEFAULT NULL::text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id       uuid;
    v_run_id            uuid;
    v_run_agency        uuid;
    v_run_status        text;
    v_compare_presented timestamptz;
    v_current_status    text;
    v_prior_reason_code text;
    v_prior_reason_text text;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: no active operator for the calling session';
    END IF;

    IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
        RAISE EXCEPTION 'exclude_candidate: reason code is required';
    END IF;
    IF p_reason_code = 'R-999' AND (p_reason_text IS NULL OR btrim(p_reason_text) = '') THEN
        RAISE EXCEPTION 'exclude_candidate: reason text is required when reason code is R-999';
    END IF;

    SELECT run_id INTO v_run_id FROM public.candidate WHERE id = p_candidate_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'exclude_candidate: candidate % not found', p_candidate_id;
    END IF;

    SELECT agency_id, run_status, compare_presented_at INTO v_run_agency, v_run_status, v_compare_presented
      FROM public.run WHERE id = v_run_id FOR UPDATE;

    SELECT status, exclusion_reason_code, excluded_reason
      INTO v_current_status, v_prior_reason_code, v_prior_reason_text
      FROM public.candidate WHERE id = p_candidate_id FOR UPDATE;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'exclude_candidate: candidate does not belong to caller''s agency';
    END IF;

    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'exclude_candidate: run is %, candidate can no longer be modified', v_run_status;
    END IF;

    IF v_current_status = 'excluded' THEN
        RAISE EXCEPTION 'exclude_candidate: candidate is already excluded';
    END IF;

    UPDATE public.candidate
       SET status = 'excluded',
           exclusion_reason_code = p_reason_code,
           excluded_reason = nullif(btrim(coalesce(p_reason_text,'')),''),
           excluded_by = v_operator_id,
           excluded_at = now()
     WHERE id = p_candidate_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'exclusion_reason_recorded', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'reason', p_reason_text));

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'exclusion_reason_coded', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'code', p_reason_code, 'memo', p_reason_text));

    IF v_compare_presented IS NOT NULL THEN
        UPDATE public.run SET compare_presented_at = NULL WHERE id = v_run_id;
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (v_run_id, 'compare_presented', v_operator_id,
                jsonb_build_object(
                    'invalidated', true,
                    'invalidated_reason', 'candidate_excluded_after_presentation',
                    'candidate_id', p_candidate_id,
                    'previous_presented_at', v_compare_presented,
                    'before', jsonb_build_object('status', v_current_status, 'reason_code', v_prior_reason_code, 'reason_text', v_prior_reason_text),
                    'after', jsonb_build_object('status', 'excluded', 'reason_code', p_reason_code, 'reason_text', p_reason_text)
                ));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_candidate_coverage_status(
    p_candidate_id uuid, p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id       uuid;
    v_run_id            uuid;
    v_run_agency        uuid;
    v_run_status        text;
    v_compare_presented timestamptz;
    v_candidate_status  text;
    v_current_status    text;
BEGIN
    IF p_status IS NULL OR p_status NOT IN ('full','partial','none') THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: invalid status %', p_status;
    END IF;

    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: no active operator for the calling session';
    END IF;

    SELECT run_id INTO v_run_id FROM public.candidate WHERE id = p_candidate_id;
    IF v_run_id IS NULL THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate % not found', p_candidate_id;
    END IF;

    SELECT agency_id, run_status, compare_presented_at INTO v_run_agency, v_run_status, v_compare_presented
      FROM public.run WHERE id = v_run_id FOR UPDATE;

    SELECT status, coverage_status INTO v_candidate_status, v_current_status
      FROM public.candidate WHERE id = p_candidate_id FOR UPDATE;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate does not belong to caller''s agency';
    END IF;

    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: run is %, candidate can no longer be modified', v_run_status;
    END IF;

    IF v_candidate_status = 'excluded' THEN
        RAISE EXCEPTION 'update_candidate_coverage_status: candidate is excluded, coverage status can no longer be modified';
    END IF;

    IF v_current_status IS NOT DISTINCT FROM p_status THEN
        RETURN;
    END IF;

    UPDATE public.candidate SET coverage_status = p_status WHERE id = p_candidate_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (v_run_id, 'candidate_coverage_status_updated', v_operator_id,
            jsonb_build_object('candidate_id', p_candidate_id, 'status', p_status,
                                'old_status', v_current_status));

    IF v_compare_presented IS NOT NULL THEN
        UPDATE public.run SET compare_presented_at = NULL WHERE id = v_run_id;
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (v_run_id, 'compare_presented', v_operator_id,
                jsonb_build_object(
                    'invalidated', true,
                    'invalidated_reason', 'candidate_coverage_status_changed_after_presentation',
                    'candidate_id', p_candidate_id,
                    'previous_presented_at', v_compare_presented,
                    'before', jsonb_build_object('coverage_status', v_current_status),
                    'after', jsonb_build_object('coverage_status', p_status)
                ));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_compare_presented(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id  uuid;
    v_run_agency   uuid;
    v_run_status   text;
    v_already      timestamptz;
    v_active_count int;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_compare_presented: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status, compare_presented_at INTO v_run_agency, v_run_status, v_already
      FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_compare_presented: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_compare_presented: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'record_compare_presented: run is %', v_run_status;
    END IF;
    IF v_already IS NOT NULL THEN
        RAISE EXCEPTION 'record_compare_presented: already presented';
    END IF;

    SELECT count(*) INTO v_active_count FROM public.candidate WHERE run_id = p_run_id AND status = 'active';
    IF v_active_count = 0 THEN
        RAISE EXCEPTION 'record_compare_presented: at least one active candidate is required';
    END IF;

    UPDATE public.run SET compare_presented_at = now() WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'compare_presented', v_operator_id, jsonb_build_object('presented_at', now()));
END;
$$;

CREATE OR REPLACE FUNCTION public.record_insurer_list_presented(p_run_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id uuid;
    v_run_agency  uuid;
    v_run_status  text;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'record_insurer_list_presented: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status INTO v_run_agency, v_run_status FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run % not found', p_run_id;
    END IF;
    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run does not belong to caller''s agency';
    END IF;
    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'record_insurer_list_presented: run is %', v_run_status;
    END IF;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'insurer_list_presented', v_operator_id, jsonb_build_object('auto_recorded', true));
END;
$$;

CREATE OR REPLACE FUNCTION public.save_property_profile(
    p_run_id uuid, p_line_code text, p_municipality_code text, p_attributes jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
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
    SELECT id, agency_id INTO v_operator_id, v_agency_id
    FROM public.operator WHERE auth_user_id = auth.uid() AND is_active = true;
    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 呼出ユーザーが特定できません';
    END IF;

    SELECT agency_id, customer_type, run_status INTO v_run_agency, v_customer_type, v_run_status
    FROM public.run WHERE id = p_run_id FOR UPDATE;
    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'save_property_profile: 対象runが存在しません';
    END IF;
    IF v_run_agency IS DISTINCT FROM v_agency_id THEN
        RAISE EXCEPTION 'save_property_profile: 権限がありません（他代理店のrun）';
    END IF;

    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'save_property_profile: run is %, property profile can no longer be modified', v_run_status;
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

-- ── 是正2-c: finalize_run の証跡検証をサーバー側算出に置き換える ───────────
CREATE OR REPLACE FUNCTION public.finalize_run(
    p_run_id uuid,
    p_pdf_object_key text,
    p_pdf_sha256 text,
    p_consent_comparison_result boolean DEFAULT false,
    p_consent_important_matters boolean DEFAULT false,
    p_consent_personal_info boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    v_operator_id                 uuid;
    v_run_agency                  uuid;
    v_run_status                  text;
    v_customer_decision           text;
    v_compare_presented_at        timestamptz;
    v_meeting_scene               varchar;
    v_important_matters_delivered boolean;
    v_recording_mode              text;
    v_post_record_status          text;
    v_exception_route             boolean;
    v_snapshot_count              int;
    v_unresolved_count            int;
    v_insurer_list_event_count    int;
    v_proof_key                   text;
    v_proof_payload               text;
    v_computed_sha                text;
    v_obj_metadata                jsonb;
    v_etag                        text;
BEGIN
    SELECT id INTO v_operator_id
      FROM public.operator
     WHERE auth_user_id = auth.uid() AND is_active = true;

    IF v_operator_id IS NULL THEN
        RAISE EXCEPTION 'finalize_run: no active operator for the calling session';
    END IF;

    SELECT agency_id, run_status, customer_decision, compare_presented_at,
           meeting_scene, important_matters_delivered, recording_mode, post_record_status
      INTO v_run_agency, v_run_status, v_customer_decision, v_compare_presented_at,
           v_meeting_scene, v_important_matters_delivered, v_recording_mode, v_post_record_status
      FROM public.run
     WHERE id = p_run_id
     FOR UPDATE;

    IF v_run_agency IS NULL THEN
        RAISE EXCEPTION 'finalize_run: run % not found', p_run_id;
    END IF;

    IF v_run_agency IS DISTINCT FROM (SELECT agency_id FROM public.operator WHERE id = v_operator_id) THEN
        RAISE EXCEPTION 'finalize_run: run does not belong to caller''s agency';
    END IF;

    IF v_run_status NOT IN ('draft', 'post_record_pending') THEN
        RAISE EXCEPTION 'finalize_run: run is %, finalization is not permitted', v_run_status;
    END IF;

    IF v_customer_decision IS NULL
       OR v_customer_decision NOT IN ('compare', 'renewal_no_change', 'information_refused', 'comparison_waived')
    THEN
        RAISE EXCEPTION 'finalize_run: customer_decision is not set to a valid value';
    END IF;
    v_exception_route := (v_customer_decision <> 'compare');

    IF v_meeting_scene IS NULL THEN
        RAISE EXCEPTION 'finalize_run: meeting_scene must be set before finalization';
    END IF;
    IF v_recording_mode IS NULL THEN
        RAISE EXCEPTION 'finalize_run: recording_mode must be set before finalization';
    END IF;

    SELECT count(*) INTO v_snapshot_count FROM public.snapshot s WHERE s.run_id = p_run_id;
    IF v_snapshot_count = 0 THEN
        RAISE EXCEPTION 'finalize_run: snapshot not found for run';
    END IF;
    IF v_snapshot_count > 1 THEN
        RAISE EXCEPTION 'finalize_run: multiple snapshot rows found for run (data integrity issue)';
    END IF;

    IF EXISTS (SELECT 1 FROM public.snapshot s WHERE s.run_id = p_run_id AND s.unresolved_items IS NULL) THEN
        RAISE EXCEPTION 'finalize_run: snapshot.unresolved_items is NULL (data integrity issue)';
    END IF;

    SELECT coalesce(array_length(s.unresolved_items, 1), 0) INTO v_unresolved_count
      FROM public.snapshot s WHERE s.run_id = p_run_id;
    IF v_unresolved_count > 0 THEN
        RAISE EXCEPTION 'finalize_run: unresolved_items remain (% items)', v_unresolved_count;
    END IF;

    SELECT count(*) INTO v_insurer_list_event_count
      FROM public.audit_event
     WHERE run_id = p_run_id AND event_type = 'insurer_list_presented';
    IF v_insurer_list_event_count = 0 THEN
        RAISE EXCEPTION 'finalize_run: insurer_list_presented not recorded';
    END IF;

    IF NOT v_exception_route AND v_recording_mode = 'post_record' AND v_post_record_status IS DISTINCT FROM 'phase2_done' THEN
        RAISE EXCEPTION 'finalize_run: post_record phase2 not completed';
    END IF;

    IF NOT v_exception_route AND v_compare_presented_at IS NULL THEN
        RAISE EXCEPTION 'finalize_run: compare_presented_at not set';
    END IF;

    IF NOT v_important_matters_delivered THEN
        RAISE EXCEPTION 'finalize_run: important_matters_delivered not confirmed';
    END IF;

    IF p_pdf_object_key IS NULL OR btrim(p_pdf_object_key) = '' THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key is required';
    END IF;
    IF p_pdf_object_key NOT LIKE ('runs/' || p_run_id::text || '/%') THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key does not belong to this run';
    END IF;
    IF p_pdf_sha256 IS NULL OR p_pdf_sha256 !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_sha256 is not a valid SHA-256 hex digest';
    END IF;

    -- ────────────────────────────────────────────────────────────────────
    -- 証跡の内容検証（migration 056で全面的に置き換え）
    --
    -- 054では user_metadata->>'sha256'（アップロード時に呼出し元が任意に
    -- 付与できる値）と p_pdf_sha256 を突き合わせていたが、両方とも同一の
    -- 呼出し元が渡す値であるため、内容が異なっていても検査を通過できた。
    -- 056では次の3段で検証する。
    --   (1) 証跡本文をDBから取り出し、SHA-256を **DB側で算出** して
    --       p_pdf_sha256 と一致することを要求する（申告値を信用しない）
    --   (2) Storage上に当該オブジェクトが実在することを要求する
    --   (3) Storageサービスが実バイト列から書き込む metadata（size・eTag。
    --       user_metadata とは別物で呼出し元は偽装できない）が、DB上の
    --       本文と一致することを要求する＝保存された実体の内容一致
    -- ────────────────────────────────────────────────────────────────────
    SELECT object_key, payload INTO v_proof_key, v_proof_payload
      FROM public.run_proof WHERE run_id = p_run_id;

    IF v_proof_payload IS NULL THEN
        RAISE EXCEPTION 'finalize_run: proof payload is not registered for this run (call save_run_proof() before finalizing)';
    END IF;
    IF v_proof_key IS DISTINCT FROM p_pdf_object_key THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_object_key (%) does not match the registered proof object key (%)',
            p_pdf_object_key, v_proof_key;
    END IF;

    v_computed_sha := encode(extensions.digest(v_proof_payload, 'sha256'), 'hex');
    IF v_computed_sha <> p_pdf_sha256 THEN
        RAISE EXCEPTION 'finalize_run: p_pdf_sha256 does not match the SHA-256 computed by the database from the stored proof content';
    END IF;

    SELECT o.metadata INTO v_obj_metadata
      FROM storage.objects o
     WHERE o.bucket_id = 'proofs' AND o.name = p_pdf_object_key;

    IF v_obj_metadata IS NULL THEN
        RAISE EXCEPTION 'finalize_run: proof document not found in storage (upload it to proofs/% before finalizing)', p_pdf_object_key;
    END IF;

    IF (v_obj_metadata->>'size')::bigint IS DISTINCT FROM octet_length(v_proof_payload)::bigint THEN
        RAISE EXCEPTION 'finalize_run: stored proof size (%) does not match the registered proof content (% bytes)',
            v_obj_metadata->>'size', octet_length(v_proof_payload);
    END IF;

    -- eTagは単一パートアップロードでは実バイト列のMD5。Storage側の実装差で
    -- MD5形式でない場合は、この段の判定を行わない（size一致とDB側SHA-256
    -- 算出による保証は維持される）。
    v_etag := btrim(coalesce(v_obj_metadata->>'eTag', ''), '"');
    IF v_etag ~ '^[0-9a-f]{32}$' AND v_etag <> md5(v_proof_payload) THEN
        RAISE EXCEPTION 'finalize_run: stored proof content does not match the registered proof content (eTag/MD5 mismatch)';
    END IF;

    UPDATE public.run SET
        pdf_object_key = p_pdf_object_key,
        pdf_sha256     = p_pdf_sha256,
        finalized_at   = now(),
        finalized_by   = v_operator_id,
        run_status     = 'finalized',
        export_status  = 'completed',
        updated_at     = now()
    WHERE id = p_run_id;

    INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
    VALUES (p_run_id, 'run_finalized', v_operator_id, jsonb_build_object('finalized_at', now()));

    IF p_consent_comparison_result THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_comparison_result', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;

    IF p_consent_important_matters THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_important_matters', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;

    IF p_consent_personal_info THEN
        INSERT INTO public.audit_event (run_id, event_type, operator_id, payload)
        VALUES (p_run_id, 'consent_personal_info', v_operator_id, jsonb_build_object('obtained_at', now()));
    END IF;
END;
$$;
