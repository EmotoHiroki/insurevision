-- ============================================================
-- InsureVision M1 v4.1 — FINAL CONSOLIDATED SCHEMA
-- Single source of truth for Supabase SQL Editor
--
-- HOW TO USE:
--   Fresh install  → run this entire file top-to-bottom
--   Already live   → DO NOT re-run (DB is already correct)
--
-- Last updated: 2026-03-18
-- ============================================================


-- ============================================================
-- SECTION 1 — CLEAN SLATE (drops everything and rebuilds)
-- ============================================================

DROP TABLE IF EXISTS audit_event  CASCADE;
DROP TABLE IF EXISTS candidate    CASCADE;
DROP TABLE IF EXISTS snapshot     CASCADE;
DROP TABLE IF EXISTS run          CASCADE;
DROP TABLE IF EXISTS operator     CASCADE;

DROP FUNCTION IF EXISTS finalize_run(uuid, text, text, uuid, boolean);


-- ============================================================
-- SECTION 2 — TABLES
-- ============================================================

-- operator
-- One row per licensed recruiter / manager / admin.
-- auth_user_id links to Supabase Auth.
CREATE TABLE operator (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    agency_id           uuid        NOT NULL,
    name                text        NOT NULL,
    email               text        UNIQUE,
    auth_user_id        uuid        UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    license_number      text        NOT NULL DEFAULT '',
    license_valid_until date,
    role                text        NOT NULL DEFAULT 'agent'
                                    CHECK (role IN ('agent', 'manager', 'admin')),
    is_active           boolean     NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- run
-- Core unit of work: one run = one insurance recruitment session.
CREATE TABLE run (
    id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    agency_id             uuid        NOT NULL,
    operator_id           uuid        NOT NULL REFERENCES operator(id),
    product_line          text        NOT NULL DEFAULT 'auto',
    customer_type         text        NOT NULL
                                      CHECK (customer_type IN ('individual', 'corporate')),
    customer_ref          text        NOT NULL,
    run_type              text        NOT NULL
                                      CHECK (run_type IN ('new_contract', 'renewal')),
    run_status            text        NOT NULL DEFAULT 'draft'
                                      CHECK (run_status IN ('draft', 'finalized', 'archived')),
    compliance_mode       text        CHECK (compliance_mode IN ('full', 'exception')),

    -- Step 3: Intent
    customer_decision     text        CHECK (customer_decision IN (
                                          'compare',
                                          'renewal_no_change',
                                          'information_refused',
                                          'comparison_waived'
                                      )),
    customer_decision_at  timestamptz,
    customer_intent_memo  text,

    -- Step 2: Issue Sharing
    diagnosis_memo        text,

    -- Step 4: Comparison Scope
    comparison_scope      text        CHECK (comparison_scope IN ('same_insurer', 'multi_insurer')),
    comparison_scope_memo text,

    -- Step 5: Priority
    -- priority_weight keys must be a strict subset of priority_factors (enforced in API layer)
    priority_factors      text[],
    priority_weight       jsonb,

    -- Comparison screen
    compare_presented_at  timestamptz,

    -- Finalize (set atomically by finalize_run() function)
    finalized_at          timestamptz,
    finalized_by          uuid        REFERENCES operator(id),
    pdf_object_key        text,
    pdf_sha256            text,
    export_status         text        CHECK (export_status IN (
                                          'pending', 'generating', 'completed', 'delivered', 'failed'
                                      )),

    -- Meta
    core_logic_version    text        NOT NULL DEFAULT '2.0.0',
    is_test               boolean     NOT NULL DEFAULT false,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);

-- snapshot
-- Exactly ONE snapshot per run (UNIQUE run_id).
-- Stores the core-logic output (missing/uncertain flags) and
-- the recruiter's manual-review outcome (confirmed/supplemented/unresolved).
CREATE TABLE snapshot (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id             uuid        NOT NULL UNIQUE REFERENCES run(id) ON DELETE CASCADE,
    csv_imported       boolean     NOT NULL DEFAULT false,
    pdf_object_key     text,

    -- Core-logic flag output (array of {flag_key, label, guide_message} objects)
    missing_flags      jsonb       NOT NULL DEFAULT '[]',
    uncertain_flags    jsonb       NOT NULL DEFAULT '[]',

    -- Manual review outcome
    -- unresolved_items non-empty = Fail-Closed gate blocks Finalize (TC10/TC11)
    confirmed_items    text[]      NOT NULL DEFAULT '{}',
    supplemented_items text[]      NOT NULL DEFAULT '{}',
    unresolved_items   text[]      NOT NULL DEFAULT '{}',

    reviewed_at        timestamptz,
    reviewed_by        uuid        REFERENCES operator(id),
    core_logic_version text        NOT NULL DEFAULT '2.0.0',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);

-- candidate
-- Each run can have multiple insurance product candidates to compare.
-- same_insurer scope: role='current' + role='recommended' (2 fixed columns)
-- multi_insurer scope: dynamic columns, role can be null
CREATE TABLE candidate (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id          uuid        NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    slot_no         integer     NOT NULL,
    role            text        CHECK (role IN ('current', 'recommended')),
    insurer_code    text,
    insurer_name    text        NOT NULL,
    product_name    text,
    annual_premium  integer,
    diff_flags      jsonb,
    reason_code     text,
    status          text        NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'excluded')),
    excluded_reason text,
    excluded_at     timestamptz,
    excluded_by     uuid        REFERENCES operator(id),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (run_id, slot_no)
);

-- audit_event
-- Append-only compliance trail. Never update or delete rows.
-- 11 event types per M1 v4.1 spec.
CREATE TABLE audit_event (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id      uuid        NOT NULL REFERENCES run(id) ON DELETE CASCADE,
    event_type  text        NOT NULL CHECK (event_type IN (
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
    operator_id uuid        NOT NULL REFERENCES operator(id),
    payload     jsonb,
    occurred_at timestamptz NOT NULL DEFAULT now()
);


-- ============================================================
-- SECTION 3 — INDEXES
-- ============================================================

CREATE INDEX idx_run_agency_id      ON run(agency_id);
CREATE INDEX idx_run_status         ON run(run_status);
CREATE INDEX idx_run_operator_id    ON run(operator_id);
CREATE INDEX idx_snapshot_run_id    ON snapshot(run_id);
CREATE INDEX idx_candidate_run_id   ON candidate(run_id);
CREATE INDEX idx_audit_event_run_id ON audit_event(run_id);
CREATE INDEX idx_audit_event_time   ON audit_event(occurred_at);


-- ============================================================
-- SECTION 4 — FINALIZE FUNCTION (atomic transaction)
-- Implements M1 v4.1 spec Section 4 Steps 6–7.
--
-- STEP 6: run UPDATE only (no audit_event touches)
-- STEP 7: audit_event INSERT only (no run touches)
-- Both happen in one DB transaction — either both commit or both roll back.
-- Called by POST /api/finalize after validation layer has already checked:
--   • run.run_status = 'draft'
--   • snapshot.unresolved_items = [] (Fail-Closed gate — TC10/TC11)
--   • compare_presented_at is set (compare path only)
-- ============================================================

CREATE OR REPLACE FUNCTION finalize_run(
    p_run_id                    uuid,
    p_pdf_object_key            text,
    p_pdf_sha256                text,
    p_operator_id               uuid,
    p_consent_comparison_result boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- ── STEP 6: run UPDATE ────────────────────────────────────────────────
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

    IF NOT FOUND THEN
        RAISE EXCEPTION 'finalize_run: run % not found or not in draft status', p_run_id;
    END IF;

    -- ── STEP 7: audit_event INSERT ────────────────────────────────────────
    -- Always record run_finalized
    INSERT INTO audit_event (run_id, event_type, operator_id, payload)
    VALUES (
        p_run_id,
        'run_finalized',
        p_operator_id,
        jsonb_build_object('finalized_at', now())
    );

    -- Compare path: record consent_comparison_result if given
    IF p_consent_comparison_result THEN
        INSERT INTO audit_event (run_id, event_type, operator_id, payload)
        VALUES (
            p_run_id,
            'consent_comparison_result',
            p_operator_id,
            jsonb_build_object('obtained_at', now())
        );
    END IF;

    -- COMMIT is implicit when function returns without error
END;
$$;


-- ============================================================
-- SECTION 5 — ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE operator    ENABLE ROW LEVEL SECURITY;
ALTER TABLE run         ENABLE ROW LEVEL SECURITY;
ALTER TABLE snapshot    ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidate   ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_event ENABLE ROW LEVEL SECURITY;

-- operator: any authenticated user can read all operators (needed to resolve names)
--           update only allowed on own row
CREATE POLICY "operator_select_all"   ON operator FOR SELECT TO authenticated USING (true);
CREATE POLICY "operator_insert_self"  ON operator FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "operator_update_self"  ON operator FOR UPDATE TO authenticated USING (auth.uid() = auth_user_id);

-- run / snapshot / candidate / audit_event:
-- Full access for authenticated users (dev/demo).
-- For production: replace USING (true) with agency-scoped sub-select (see comment below).
CREATE POLICY "run_authenticated_all"         ON run         AS PERMISSIVE FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "snapshot_authenticated_all"    ON snapshot    AS PERMISSIVE FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "candidate_authenticated_all"   ON candidate   AS PERMISSIVE FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "audit_event_authenticated_all" ON audit_event AS PERMISSIVE FOR ALL TO authenticated USING (true) WITH CHECK (true);

/*
  PRODUCTION UPGRADE (replace the 4 permissive policies above):

  CREATE POLICY "run_own_agency" ON run
      USING (agency_id = (SELECT agency_id FROM operator WHERE auth_user_id = auth.uid() LIMIT 1));
  -- Apply same pattern to snapshot / candidate / audit_event via run_id sub-select.
*/


-- ============================================================
-- SECTION 6 — API CACHE REFRESH
-- Must run after any schema change so PostgREST picks it up.
-- ============================================================

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- SECTION 7 — SEED OPERATOR (dev / demo only)
-- Replace the UUID and name before running in production.
-- ON CONFLICT = safe to re-run: updates name if row already exists.
-- ============================================================

-- INSERT INTO public.operator (agency_id, name, auth_user_id, role)
-- VALUES (
--   '00000000-0000-0000-0000-000000000000',  -- replace with real agency_id
--   'Test Admin',
--   '12612143-f6fa-4ee4-b44f-28004a185869',  -- replace with real auth.users id
--   'admin'
-- )
-- ON CONFLICT (auth_user_id) DO UPDATE SET name = EXCLUDED.name;
