// =============================================
// Database Types
// =============================================

export type RunStatus = 'draft' | 'finalizing' | 'finalized' | 'finalizing_failed' | 'cancelled'
export type CustomerType = 'individual' | 'corporate'
export type RunType = 'new_contract' | 'renewal'
export type CandidateStatus = 'active' | 'excluded'
export type OperatorRole = 'agent' | 'manager' | 'admin'
export type ComplianceMode = 'none' | 'i_compare_info' | 'ro_recommendation'
export type SignaturePolicy = 'none' | 'optional' | 'required'
export type DeliveryMethod = 'in_person' | 'email' | 'mail' | 'other'
export type IntentionConfirmMethod = 'face_to_face' | 'phone' | 'written' | 'other'

export type CustomerDecision =
    | 'compare_requested'
    | 'status_quo_selected'
    | 'delegated_to_agent'
    | 'externally_designated'
    | 'new_contract_minimum'
    | 'limited_by_underwriting'
    | 'renewal_no_change'
    | 'urgent_by_customer'
    | 'information_refused'
    | 'other'

export type FinalChoiceReasonCode =
    | 'existing_relationship'
    | 'price_priority'
    | 'coverage_priority'
    | 'externally_designated'
    | 'time_constraint'
    | 'other'

export type DesignationScope = 'insurer' | 'product' | 'other'

export type AlternativeReasonCode =
    | 'only_available'
    | 'equivalent_coverage'
    | 'lowest_premium'
    | 'customer_preference'
    | 'other'

export type AuditEventType =
    | 'created'
    | 'updated'
    | 'finalized'
    | 'cancelled'
    | 'whitelist_updated'
    | 'compare_viewed'
    | 'alternatives_disclosed'

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
    license_valid_until: string
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
    parent_run_id: string | null
    amendment_reason: string | null
    previous_run_id: string | null
    run_status: RunStatus
    finalized_at: string | null
    finalized_by: string | null
    compliance_mode: ComplianceMode | null
    customer_decision: CustomerDecision | null
    customer_decision_at: string | null
    intention_confirmed_at: string | null
    intention_confirm_method: IntentionConfirmMethod | null
    intention_summary: string | null
    priority_factors: string[] | null
    priority_factors_note: string | null
    recommended_candidate_id: string | null
    final_candidate_id: string | null
    compare_presented_at: string | null
    alternatives_disclosed: boolean
    compared_company_names: Record<string, string> | null
    final_choice_reason_code: FinalChoiceReasonCode | null
    final_choice_reason_text: string | null
    designation_scope: DesignationScope | null
    designation_reason: string | null
    restriction_reason_code: string | null
    restriction_note: string | null
    alternative_reason_code: AlternativeReasonCode | null
    alternative_reason_text: string | null
    delivered_at: string | null
    delivery_method: DeliveryMethod | null
    delivered_recorded_at: string | null
    delivered_recorded_by: string | null
    pdf_sha256: string | null
    pdf_object_key: string | null
    signature_policy: SignaturePolicy
    signature_obtained: boolean
    signature_obtained_at: string | null
    signature_obtained_by: string | null
    kyc_confirmed: boolean
    kyc_confirmed_at: string | null
    core_logic_version: string
    reviewed_by: string | null
    reviewed_at: string | null
    disadvantage_explained: boolean | null
    is_manual_entry: boolean
    manual_reason: string | null
    exception_flag: boolean
    exception_reason: string | null
    exception_approved_by: string | null
    exception_approved_at: string | null
    is_test: boolean
    created_at: string
    updated_at: string
}

export interface Candidate {
    id: string
    run_id: string
    slot_no: number
    insurer_name: string
    product_name: string | null
    annual_premium: number | null
    status: CandidateStatus
    excluded_reason: string | null
    excluded_at: string | null
    excluded_by: string | null
    created_at: string
    updated_at: string
}

export interface Snapshot {
    id: string
    run_id: string
    candidate_id: string
    product_version: string
    source_date: string
    product_name: string
    annual_cost: number
    coverage_a: string | null
    coverage_b: string | null
    coverage_c: string | null
    option_a_flag: boolean | null
    option_b_flag: boolean | null
    option_c_flag: boolean | null
    option_c_note: string | null
    service_note: string | null
    key_exclusions: string | null
    completeness_score: number | null
    core_logic_version: string
    created_at: string
    updated_at: string
}

export interface RunParticipant {
    id: string
    run_id: string
    operator_id: string
    role: 'primary' | 'co' | 'reviewer'
    joined_at: string
}

export interface AuditEvent {
    id: string
    run_id: string
    entity_type: string
    entity_id: string
    event_type: AuditEventType
    field_name: string | null
    old_value: Record<string, unknown> | null
    new_value: Record<string, unknown> | null
    operator_id: string
    occurred_at: string
    ip_address: string | null
}

export interface RestrictionReasonMaster {
    code: string
    label: string
    is_active: boolean
    sort_order: number
}

export interface AgencyConfig {
    id: string
    agency_id: string
    agency_name: string
    signature_policy: SignaturePolicy
    created_at: string
    updated_at: string
}

// =============================================
// Form / Insert types
// =============================================

export type RunInsert = Omit<Run, 'id' | 'created_at' | 'updated_at' | 'finalized_at' | 'finalized_by' | 'delivered_recorded_at' | 'delivered_recorded_by' | 'signature_obtained_at' | 'signature_obtained_by' | 'kyc_confirmed_at' | 'exception_approved_at' | 'reviewed_at' | 'customer_decision_at' | 'compare_presented_at' | 'excluded_at'>

export type RunUpdate = Partial<Omit<Run, 'id' | 'agency_id' | 'operator_id' | 'created_at'>>

export type CandidateInsert = Omit<Candidate, 'id' | 'created_at' | 'updated_at' | 'excluded_at' | 'excluded_by'>
