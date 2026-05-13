-- =============================================
-- M1 v4.1 Schema Migration
-- =============================================

-- operator table
CREATE TABLE IF NOT EXISTS operator (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agency_id        uuid NOT NULL,
    name             text NOT NULL,
    email            text,
    auth_user_id     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    license_number   text NOT NULL DEFAULT '',
    license_valid_until date,
    role             text NOT NULL DEFAULT 'agent'
                       CHECK (role IN ('agent','manager','admin')),
    is_active        boolean NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

-- run table
CREATE TABLE IF NOT EXISTS run (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agency_id            uuid NOT NULL,
    operator_id          uuid NOT NULL REFERENCES operator(id),
    product_line         text NOT NULL DEFAULT '',
    customer_type        text NOT NULL
                           CHECK (customer_type IN ('individual','corporate')),
    customer_ref         text NOT NULL,
    run_type             text NOT NULL
                           CHECK (run_type IN ('new_contract','renewal')),
    run_status           text NOT NULL DEFAULT 'draft'
                           CHECK (run_status IN ('draft','finalized','archived')),
    compliance_mode      text
                           CHECK (compliance_mode IN ('full','exception')),
    -- Step 3: Intent
    customer_decision    text
                           CHECK (customer_decision IN (
                               'compare','renewal_no_change',
                               'information_refused','comparison_waived'
                           )),
    customer_decision_at timestamptz,
    customer_intent_memo text,
    -- Step 2: Issue Sharing
    diagnosis_memo       text,
    -- Step 4: Comparison Scope
    comparison_scope     text
                           CHECK (comparison_scope IN ('same_insurer','multi_insurer')),
    comparison_scope_memo text,
    -- Step 5: Priority
    priority_factors     text[],
    priority_weight      jsonb,    -- keys must be subset of priority_factors (validated in API)
    -- Comparison screen
    compare_presented_at timestamptz,
    -- Finalize
    finalized_at         timestamptz,
    finalized_by         uuid REFERENCES operator(id),
    pdf_object_key       text,
    pdf_sha256           text,
    export_status        text
                           CHECK (export_status IN (
                               'pending','generating','completed','delivered','failed'
                           )),
    -- Meta
    core_logic_version   text NOT NULL DEFAULT '2.0.0',
    is_test              boolean NOT NULL DEFAULT false,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);

-- snapshot table (one per run)
CREATE TABLE IF NOT EXISTS snapshot (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id             uuid NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    csv_imported       boolean NOT NULL DEFAULT false,
    pdf_object_key     text,
    -- Core logic output
    missing_flags      jsonb NOT NULL DEFAULT '[]',
    uncertain_flags    jsonb NOT NULL DEFAULT '[]',
    -- Manual review outcome
    confirmed_items    text[] NOT NULL DEFAULT '{}',
    supplemented_items text[] NOT NULL DEFAULT '{}',
    unresolved_items   text[] NOT NULL DEFAULT '{}',
    -- Audit
    reviewed_at        timestamptz,
    reviewed_by        uuid REFERENCES operator(id),
    core_logic_version text NOT NULL DEFAULT '2.0.0',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id)    -- one snapshot per run
);

-- candidate table
CREATE TABLE IF NOT EXISTS candidate (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id          uuid NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    slot_no         integer NOT NULL,
    role            text CHECK (role IN ('current','recommended')),
    insurer_code    text,
    insurer_name    text NOT NULL,
    product_name    text,
    annual_premium  integer,
    diff_flags      jsonb,
    reason_code     text,
    status          text NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','excluded')),
    excluded_reason text,
    excluded_at     timestamptz,
    excluded_by     uuid REFERENCES operator(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id, slot_no)
);

-- audit_event table
CREATE TABLE IF NOT EXISTS audit_event (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id      uuid NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    event_type  text NOT NULL CHECK (event_type IN (
                    'issue_shared',
                    'manual_review_completed',
                    'insurer_list_presented',
                    'customer_intent_confirmed',
                    'compare_presented',
                    'exclusion_reason_recorded',
                    'comparison_waiver_confirmed',
                    'consent_important_matters',
                    'consent_personal_info',
                    'consent_comparison_result',
                    'run_finalized'
                )),
    operator_id uuid NOT NULL REFERENCES operator(id),
    payload     jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now()
);

-- =============================================
-- Indexes
-- =============================================

CREATE INDEX IF NOT EXISTS idx_run_agency_id       ON run(agency_id);
CREATE INDEX IF NOT EXISTS idx_run_status          ON run(run_status);
CREATE INDEX IF NOT EXISTS idx_run_operator_id     ON run(operator_id);
CREATE INDEX IF NOT EXISTS idx_snapshot_run_id     ON snapshot(run_id);
CREATE INDEX IF NOT EXISTS idx_candidate_run_id    ON candidate(run_id);
CREATE INDEX IF NOT EXISTS idx_audit_event_run_id  ON audit_event(run_id);
CREATE INDEX IF NOT EXISTS idx_audit_event_time    ON audit_event(occurred_at);

-- =============================================
-- Row Level Security
-- =============================================

ALTER TABLE operator     ENABLE ROW LEVEL SECURITY;
ALTER TABLE run          ENABLE ROW LEVEL SECURITY;
ALTER TABLE snapshot     ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidate    ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_event  ENABLE ROW LEVEL SECURITY;

-- operator: each row is accessible by its own auth user
CREATE POLICY "operator_self" ON operator
    USING (auth_user_id = auth.uid());

-- run: scoped to same agency as the logged-in operator
CREATE POLICY "run_own_agency" ON run
    USING (
        agency_id = (
            SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() LIMIT 1
        )
    );

-- snapshot: accessible if the parent run is accessible
CREATE POLICY "snapshot_own_agency" ON snapshot
    USING (
        run_id IN (
            SELECT id FROM run WHERE agency_id = (
                SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() LIMIT 1
            )
        )
    );

-- candidate: same as snapshot
CREATE POLICY "candidate_own_agency" ON candidate
    USING (
        run_id IN (
            SELECT id FROM run WHERE agency_id = (
                SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() LIMIT 1
            )
        )
    );

-- audit_event: same as snapshot
CREATE POLICY "audit_event_own_agency" ON audit_event
    USING (
        run_id IN (
            SELECT id FROM run WHERE agency_id = (
                SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() LIMIT 1
            )
        )
    );

-- =============================================
-- household_id placeholder (Phase 1 — column only, no FK)
-- FK and households table added in Phase 2 migration
-- =============================================
-- ALTER TABLE customers ADD COLUMN household_id UUID NULL;
-- (Uncomment and run separately when customers table exists)
-- =============================================
-- finalize_run() — Atomic finalize transaction
-- Implements M1 v4.1 spec Section 4, Steps 5-8
--
-- STEP 6 (run UPDATE) and STEP 7 (audit_event INSERT)
-- are strictly separated within a single transaction.
-- =============================================

CREATE OR REPLACE FUNCTION finalize_run(
    p_run_id                     uuid,
    p_pdf_object_key             text,
    p_pdf_sha256                 text,
    p_operator_id                uuid,
    p_consent_comparison_result  boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- ── STEP 6: run table UPDATE ONLY ─────────────────────────────────────
    -- No audit_event operations here. Only run fields are touched.
    UPDATE run SET
        pdf_object_key = p_pdf_object_key,
        pdf_sha256     = p_pdf_sha256,
        finalized_at   = now(),
        finalized_by   = p_operator_id,
        run_status     = 'finalized',
        export_status  = 'completed',
        updated_at     = now()
    WHERE id         = p_run_id
      AND run_status = 'draft';

    -- Guard: if the run was not in draft, abort immediately
    IF NOT FOUND THEN
        RAISE EXCEPTION 'finalize_run: run % not found or not in draft status', p_run_id;
    END IF;

    -- ── STEP 7: audit_event INSERT ONLY ───────────────────────────────────
    -- No run table operations here. Only audit_event rows are inserted.

    -- Always insert run_finalized
    INSERT INTO audit_event (run_id, event_type, operator_id, payload)
    VALUES (
        p_run_id,
        'run_finalized',
        p_operator_id,
        jsonb_build_object('finalized_at', now())
    );

    -- Conditionally insert consent_comparison_result
    IF p_consent_comparison_result THEN
        INSERT INTO audit_event (run_id, event_type, operator_id, payload)
        VALUES (
            p_run_id,
            'consent_comparison_result',
            p_operator_id,
            jsonb_build_object('obtained_at', now())
        );
    END IF;

    -- COMMIT is implicit at function end (called within caller's transaction)
END;
$$;
-- =============================================
-- M2 Schema Migration
-- =============================================

-- run table: M2 additions
ALTER TABLE run
    ADD COLUMN IF NOT EXISTS condition_change_note  text,
    ADD COLUMN IF NOT EXISTS delivery_method        text
                                CHECK (delivery_method IN ('hand','mail','email','digital')),
    ADD COLUMN IF NOT EXISTS delivery_confirmed_at  timestamptz;

-- snapshot table: M2 additions
ALTER TABLE snapshot
    ADD COLUMN IF NOT EXISTS resolution_memo        text,
    ADD COLUMN IF NOT EXISTS redundancy_decisions   jsonb NOT NULL DEFAULT '[]';

-- candidate table: M2 additions
ALTER TABLE candidate
    ADD COLUMN IF NOT EXISTS coverage_status        text
                                CHECK (coverage_status IN ('full','partial','none')),
    ADD COLUMN IF NOT EXISTS vehicle_premises       jsonb;

-- ─────────────────────────────────────────────
-- candidate.role: extend CHECK (2 → 7 values)
-- ─────────────────────────────────────────────
ALTER TABLE candidate DROP CONSTRAINT IF EXISTS candidate_role_check;
ALTER TABLE candidate
    ADD CONSTRAINT candidate_role_check
    CHECK (role IN (
        'current',
        'recommended',
        'prior',
        'same_conditions',
        'recommended_1',
        'recommended_2',
        'recommended_3'
    ));

-- ─────────────────────────────────────────────
-- audit_event.event_type: extend CHECK (11 → 13 values)
-- ─────────────────────────────────────────────
ALTER TABLE audit_event DROP CONSTRAINT IF EXISTS audit_event_event_type_check;
ALTER TABLE audit_event
    ADD CONSTRAINT audit_event_event_type_check
    CHECK (event_type IN (
        'issue_shared',
        'manual_review_completed',
        'insurer_list_presented',
        'customer_intent_confirmed',
        'compare_presented',
        'exclusion_reason_recorded',
        'comparison_waiver_confirmed',
        'consent_important_matters',
        'consent_personal_info',
        'consent_comparison_result',
        'run_finalized',
        'delivery_recorded',
        'redundancy_resolution_recorded'
    ));

-- ─────────────────────────────────────────────
-- Data migration: same_insurer candidate roles
-- role='current'  → 'prior'          (readonly reference column)
-- role='recommended' → 'recommended_1' (first recommended plan)
-- Only for same_insurer runs — multi_insurer runs keep existing roles
-- ─────────────────────────────────────────────
UPDATE candidate c
SET role = 'prior'
WHERE c.role = 'current'
  AND EXISTS (
      SELECT 1 FROM run r
      WHERE r.id = c.run_id
        AND r.comparison_scope = 'same_insurer'
  );

UPDATE candidate c
SET role = 'recommended_1'
WHERE c.role = 'recommended'
  AND EXISTS (
      SELECT 1 FROM run r
      WHERE r.id = c.run_id
        AND r.comparison_scope = 'same_insurer'
  );
-- =============================================
-- W3 Schema Migration — G-1/G-2/G-3 + Suspension
-- =============================================

-- G-2: 顧客名
ALTER TABLE run ADD COLUMN IF NOT EXISTS customer_name text;

-- G-1: 意向確認相手
ALTER TABLE run ADD COLUMN IF NOT EXISTS intent_confirmed_with text;

-- G-3: 法人意思決定者
ALTER TABLE run ADD COLUMN IF NOT EXISTS corporate_decision_maker text;

-- Suspension flow
ALTER TABLE run ADD COLUMN IF NOT EXISTS pending_note       text;
ALTER TABLE run ADD COLUMN IF NOT EXISTS suspended_at       timestamptz;
ALTER TABLE run ADD COLUMN IF NOT EXISTS suspension_type    text
    CHECK (suspension_type IN ('condition_adjustment', 'mid_session'));

-- Extend run_status CHECK to include 'suspended'
ALTER TABLE run DROP CONSTRAINT IF EXISTS run_run_status_check;
ALTER TABLE run ADD CONSTRAINT run_run_status_check
    CHECK (run_status IN ('draft', 'finalized', 'archived', 'suspended'));
-- =============================================
-- M3 Schema Migration
-- =============================================

-- run table: M3新規カラム追加
ALTER TABLE run
    ADD COLUMN IF NOT EXISTS recording_mode text
        CHECK (recording_mode IN ('realtime', 'post_record')),
    ADD COLUMN IF NOT EXISTS input_device text
        CHECK (input_device IN ('tablet_pc', 'customer_smartphone', 'agent_smartphone')),
    ADD COLUMN IF NOT EXISTS post_record_status text
        CHECK (post_record_status IN ('phase1_done', 'phase2_done')),
    ADD COLUMN IF NOT EXISTS post_record_phase1_at timestamptz,
    ADD COLUMN IF NOT EXISTS post_record_phase2_at timestamptz,
    ADD COLUMN IF NOT EXISTS delivery_status text
        CHECK (delivery_status IN ('not_delivered', 'delivered'))
        DEFAULT 'not_delivered',
    ADD COLUMN IF NOT EXISTS delivery_reference text;

-- candidate table: 候補除外理由コード追加
ALTER TABLE candidate
    ADD COLUMN IF NOT EXISTS exclusion_reason_code text
        CHECK (exclusion_reason_code IN (
            'R-001','R-002','R-003','R-004','R-005','R-999'
        ));

-- run.run_status CHECK制約の更新（既存4値 + M3追加）
-- 既存値: draft / finalized / archived / suspended（004_w3_schema.sqlで追加済み）
ALTER TABLE run DROP CONSTRAINT IF EXISTS run_run_status_check;
ALTER TABLE run ADD CONSTRAINT run_run_status_check
    CHECK (run_status IN (
        'draft',
        'finalized',
        'archived',
        'suspended',
        'post_record_pending'
    ));

-- audit_event.event_type CHECK制約の更新（M2の13値 → M3の18値）
ALTER TABLE audit_event DROP CONSTRAINT IF EXISTS audit_event_event_type_check;
ALTER TABLE audit_event ADD CONSTRAINT audit_event_event_type_check
    CHECK (event_type IN (
        'issue_shared',
        'manual_review_completed',
        'insurer_list_presented',
        'customer_intent_confirmed',
        'compare_presented',
        'exclusion_reason_recorded',
        'comparison_waiver_confirmed',
        'consent_important_matters',
        'consent_personal_info',
        'consent_comparison_result',
        'run_finalized',
        'delivery_recorded',
        'redundancy_resolution_recorded',
        'recording_mode_selected',
        'post_record_phase1_completed',
        'post_record_phase2_completed',
        'agent_input_mode_activated',
        'exclusion_reason_coded'
    ));
