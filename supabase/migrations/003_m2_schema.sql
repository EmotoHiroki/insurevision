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
