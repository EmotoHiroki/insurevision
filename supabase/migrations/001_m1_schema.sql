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
