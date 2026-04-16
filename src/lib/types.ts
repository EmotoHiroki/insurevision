// =============================================
// Database Types — M3 v1.0
// =============================================

export type RunStatus = 'draft' | 'finalized' | 'archived' | 'suspended' | 'post_record_pending'
export type RecordingMode = 'realtime' | 'post_record'
export type InputDevice = 'tablet_pc' | 'customer_smartphone' | 'agent_smartphone'
export type PostRecordStatus = 'phase1_done' | 'phase2_done'
export type DeliveryStatus = 'not_delivered' | 'delivered'
export type ExclusionReasonCode = 'R-001' | 'R-002' | 'R-003' | 'R-004' | 'R-005' | 'R-999'
export type SuspensionType = 'condition_adjustment' | 'mid_session'
export type CustomerType = 'individual' | 'corporate'
export type RunType = 'new_contract' | 'renewal'
export type CandidateStatus = 'active' | 'excluded'
export type CandidateRole =
    | 'current'           // M1 legacy (multi_insurer runs)
    | 'recommended'       // M1 legacy (multi_insurer runs)
    | 'prior'             // M2: same_insurer —前年契約（readonly）
    | 'same_conditions'   // M2: same_insurer — 前年同条件（保険料のみ入力可）
    | 'recommended_1'     // M2: same_insurer — おすすめ1
    | 'recommended_2'     // M2: same_insurer — おすすめ2
    | 'recommended_3'     // M2: same_insurer — おすすめ3
export type CoverageStatus = 'full' | 'partial' | 'none'
export type DeliveryMethod = 'hand' | 'mail' | 'email' | 'digital'
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
    | 'delivery_recorded'               // M2: 交付記録
    | 'redundancy_resolution_recorded'  // M2: 重複補償判定記録
    | 'recording_mode_selected'         // M3: 記録方式選択
    | 'post_record_phase1_completed'    // M3: 事後記録フェーズ1完了
    | 'post_record_phase2_completed'    // M3: 事後記録フェーズ2完了
    | 'agent_input_mode_activated'      // M3: 募集人入力モード起動
    | 'exclusion_reason_coded'          // M3: 候補除外理由コード選択

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
    // G-2: 顧客名
    customer_name: string | null
    // G-1: 意向確認相手
    intent_confirmed_with: string | null
    // G-3: 法人意思決定者（corporate のみ）
    corporate_decision_maker: string | null
    // M2: Step 1 — 前提条件変更メモ（renewal時のみ）
    condition_change_note: string | null
    // Comparison screen
    compare_presented_at: string | null
    // M2: 交付記録
    delivery_method: DeliveryMethod | null
    delivery_confirmed_at: string | null
    // M3: 交付記録拡張
    delivery_status: DeliveryStatus | null
    delivery_reference: string | null
    // M3: 記録方式・入力デバイス
    recording_mode: RecordingMode | null
    input_device: InputDevice | null
    post_record_status: PostRecordStatus | null
    post_record_phase1_at: string | null
    post_record_phase2_at: string | null
    // Finalize
    finalized_at: string | null
    finalized_by: string | null
    pdf_object_key: string | null
    pdf_sha256: string | null
    export_status: ExportStatus | null
    // Suspension
    pending_note: string | null
    suspended_at: string | null
    suspension_type: SuspensionType | null
    // Meta
    core_logic_version: string
    is_test: boolean
    created_at: string
    updated_at: string
}

export interface RedundancyDecision {
    item_key: string
    decision: 'keep' | 'remove'
    reason: string
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
    // M2: 課題解消メモ・重複補償判定
    resolution_memo: string | null
    redundancy_decisions: RedundancyDecision[]
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
    // M2: 付帯状況3値化・車両別前提条件
    coverage_status: CoverageStatus | null
    vehicle_premises: Record<string, unknown>[] | null
    // M3: 候補除外理由コード
    exclusion_reason_code: ExclusionReasonCode | null
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
