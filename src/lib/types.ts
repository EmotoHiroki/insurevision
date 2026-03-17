// =============================================
// Database Types — M1 v4.1
// =============================================

export type RunStatus = 'draft' | 'finalized' | 'archived'
export type CustomerType = 'individual' | 'corporate'
export type RunType = 'new_contract' | 'renewal'
export type CandidateStatus = 'active' | 'excluded'
export type CandidateRole = 'current' | 'recommended'
export type OperatorRole = 'agent' | 'manager' | 'admin'
export type ComplianceMode = 'full' | 'exception'
export type ComparisonScope = 'same_insurer' | 'multi_insurer'
export type ExportStatus = 'pending' | 'generating' | 'completed' | 'delivered' | 'failed'

export type CustomerDecision =
    | 'compare'
    | 'renewal_no_change'
    | 'information_refused'
    | 'comparison_waived'

export type AuditEventType =
    | 'issue_shared'
    | 'manual_review_completed'
    | 'insurer_list_presented'
    | 'customer_intent_confirmed'
    | 'compare_presented'
    | 'exclusion_reason_recorded'
    | 'comparison_waiver_confirmed'
    | 'consent_important_matters'
    | 'consent_personal_info'
    | 'consent_comparison_result'
    | 'run_finalized'

// =============================================
// Table Interfaces
// =============================================

export interface Operator {
    id: string
    agency_id: string
    name: string
    email: string | null
    auth_user_id: string | null
    license_number: string
    license_valid_until: string | null
    role: OperatorRole
    is_active: boolean
    created_at: string
    updated_at: string
}

export interface Run {
    id: string
    agency_id: string
    operator_id: string
    product_line: string
    customer_type: CustomerType
    customer_ref: string
    run_type: RunType
    run_status: RunStatus
    compliance_mode: ComplianceMode | null
    // Step 3: Intent
    customer_decision: CustomerDecision | null
    customer_decision_at: string | null
    customer_intent_memo: string | null
    // Step 2: Issue Sharing
    diagnosis_memo: string | null
    // Step 4: Comparison Scope
    comparison_scope: ComparisonScope | null
    comparison_scope_memo: string | null
    // Step 5: Priority
    priority_factors: string[] | null
    priority_weight: Record<string, number> | null  // keys must be subset of priority_factors
    // Comparison screen
    compare_presented_at: string | null
    // Finalize
    finalized_at: string | null
    finalized_by: string | null
    pdf_object_key: string | null
    pdf_sha256: string | null
    export_status: ExportStatus | null
    // Meta
    core_logic_version: string
    is_test: boolean
    created_at: string
    updated_at: string
}

export interface SnapshotFlag {
    flag_key: string
    label: string
    guide_message: string
}

export interface Snapshot {
    id: string
    run_id: string
    // Import state
    csv_imported: boolean
    pdf_object_key: string | null
    // Core logic output (stored after running diagnosis)
    missing_flags: SnapshotFlag[]
    uncertain_flags: SnapshotFlag[]
    // Manual review outcome (from manual_review_completed event payload)
    confirmed_items: string[]
    supplemented_items: string[]
    unresolved_items: string[]   // non-empty blocks Finalize (Fail-Closed)
    // Audit
    reviewed_at: string | null
    reviewed_by: string | null   // operator id
    core_logic_version: string
    created_at: string
    updated_at: string
}

export interface Candidate {
    id: string
    run_id: string
    slot_no: number
    role: CandidateRole | null          // 'current' | 'recommended' for same_insurer 2-col view
    insurer_code: string | null
    insurer_name: string
    product_name: string | null
    annual_premium: number | null
    diff_flags: Record<string, unknown> | null  // coverage diff data from comparison
    reason_code: string | null          // selection / exclusion reason in comparison context
    status: CandidateStatus
    excluded_reason: string | null
    excluded_at: string | null
    excluded_by: string | null          // operator id
    created_at: string
    updated_at: string
}

export interface AuditEvent {
    id: string
    run_id: string
    event_type: AuditEventType
    operator_id: string
    payload: Record<string, unknown> | null
    occurred_at: string
}

export interface AgencyConfig {
    id: string
    agency_id: string
    agency_name: string
    created_at: string
    updated_at: string
}

// =============================================
// Minimal Proof PDF Stub (exception routes)
// =============================================

export interface MinimalProofPdfStub {
    run_id: string
    customer_ref: string
    operator_name: string
    generated_at: string
    customer_decision: CustomerDecision
    decision_reason: string
    insurer_list_presented: boolean
    insurer_names?: string[]
    consent_important_matters?: boolean
    consent_personal_info?: boolean
    consent_comparison_result?: boolean
}

// =============================================
// Form / Insert Types
// =============================================

export type RunInsert = Pick<Run,
    | 'agency_id'
    | 'operator_id'
    | 'product_line'
    | 'customer_type'
    | 'customer_ref'
    | 'run_type'
    | 'is_test'
    | 'core_logic_version'
>

export type RunUpdate = Partial<Omit<Run, 'id' | 'agency_id' | 'operator_id' | 'created_at'>>

export type SnapshotInsert = Omit<Snapshot, 'id' | 'created_at' | 'updated_at'>

export type CandidateInsert = Omit<Candidate, 'id' | 'created_at' | 'updated_at' | 'excluded_at' | 'excluded_by'>

export type AuditEventInsert = Omit<AuditEvent, 'id' | 'occurred_at'>
