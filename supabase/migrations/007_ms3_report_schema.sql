-- =============================================
-- Migration 007: MS3 Report Schema
-- Recommended/decided plan tracking
-- Plan difference reason
-- Quality check support
-- =============================================

-- MS3: Recommended and decided candidate tracking
-- Enables 3-axis comparison (prior / recommended / decided) in agency copy
ALTER TABLE run
  ADD COLUMN recommended_candidate_id UUID REFERENCES candidate(id),
  ADD COLUMN decided_candidate_id UUID REFERENCES candidate(id),
  ADD COLUMN plan_diff_reason TEXT,
  ADD COLUMN plan_diff_reason_recorded_at TIMESTAMPTZ;

-- MS3: Customer sheet and agency copy export tracking
ALTER TABLE run
  ADD COLUMN customer_sheet_generated_at TIMESTAMPTZ,
  ADD COLUMN agency_report_generated_at TIMESTAMPTZ;

-- Extend audit_event.event_type for MS3 report events
ALTER TABLE audit_event
  DROP CONSTRAINT IF EXISTS audit_event_event_type_check;

ALTER TABLE audit_event
  ADD CONSTRAINT audit_event_event_type_check
  CHECK (event_type IN (
    -- M1 (11)
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
    -- M2 (+2)
    'delivery_recorded',
    'redundancy_resolution_recorded',
    -- M3 (+5)
    'recording_mode_selected',
    'post_record_phase1_completed',
    'post_record_phase2_completed',
    'agent_input_mode_activated',
    'exclusion_reason_coded',
    -- Phase2-a (+6)
    'meeting_scene_selected',
    'electronic_consent_recorded',
    'recruiter_smartphone_confirmed',
    'customer_smartphone_confirmed',
    'paper_confirmation_completed',
    'important_matters_delivery_confirmed',
    -- MS3 report (+4)
    'recommended_plan_set',
    'decided_plan_set',
    'plan_diff_reason_recorded',
    'agency_report_generated'
  ));
