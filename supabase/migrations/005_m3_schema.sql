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
