// =============================================
// Database Types — Phase2-a v1.0
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

// =============================================
// Phase2-b-0 (MS1): 種目横断共通基盤
// =============================================

// 上位5分類コード（insurance_category テーブル）
export type InsuranceCategoryCode =
    | 'auto'            // 自動車（Phase2-a）
    | 'property'        // モノ（財物）— 火災・機械・動産総合等を収容
    | 'liability'       // 賠償責任（b-2）
    | 'person'          // ヒト — 傷害・医療・所得補償等を収容（b-3）
    | 'profit_expense'  // 利益費用（b-4）

// 実種目コード（insurance_line テーブル）— b0-MS1 では auto/fire のみ
export type InsuranceLineCode =
    | 'auto'   // 自動車（category: auto）
    | 'fire'   // 火災（category: property）

// 契約フロー種別（田島 2026-06-23 の3分類）
export type ContractFlowType =
    | 'new_complete'   // 完全新規（顧客も契約もゼロ）
    | 'new_existing'   // 新規-既存顧客（顧客あり・契約新規）
    | 'renewal'        // 継続更改（現契約あり）

// 診断基点
export type DiagnosisBaseline =
    | 'contract_diff'        // 現契約との差分（継続更改の既定）
    | 'ideal_coverage_diff'  // あるべき補償像との差分（完全新規）

// 案件フェーズ（ダッシュボード用。run_status とは独立）
export type CasePhase =
    | 'preparing'   // 準備済
    | 'in_meeting'  // 面談中
    | 'completed'   // 完了

// 補償ティア（3段階分類）
export type CoverageTier =
    | 'standard_required'  // 標準必要
    | 'needs_check'        // 要確認
    | 'optional_excluded'  // 任意・対象外

// Phase2-a: G-28 面談シーンプリセット（5種）
export type MeetingScene =
    | 'visit_smartphone'  // 訪問・スマホ連携
    | 'visit_paper'       // 訪問・ペーパー確認
    | 'pc_tablet'         // PC・タブレット型
    | 'telephone'         // 電話募集型
    | 'web_meeting'       // WEB面談

// Phase2-a: G-27 電子的方法による提供への同意確認
export type ElectronicConsentStatus =
    | 'agreed'         // 同意あり
    | 'declined'       // 同意なし → 紙面確認へ
    | 'face_confirmed' // 面談時確認
    | 'not_recorded'   // 未記録

export type ElectronicConsentMethod =
    | 'email'
    | 'url_share'
    | 'qr_code'
    | 'face_to_face'

// Phase2-a: スマホ確認ステータス
export type SmartphoneConfStatus =
    | 'not_required'
    | 'pending'
    | 'recruiter_confirmed'
    | 'customer_confirmed'
    | 'paper_fallback'

// Phase2-a: 紙面確認ステータス
export type PaperConfirmationStatus =
    | 'not_required'
    | 'pending'
    | 'completed'

// Phase2-a: 重要事項説明書交付方法
export type ImportantMattersDeliveryMethod = 'electronic' | 'paper'

// Phase2-a: CSV取込セッションステータス
export type CsvImportSessionStatus =
    | 'pending'
    | 'previewing'
    | 'confirmed'
    | 'cancelled'
    | 'error'

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
    | 'meeting_scene_selected'          // Phase2-a: G-28 面談シーン選択
    | 'electronic_consent_recorded'     // Phase2-a: G-27 電子同意確認記録
    | 'recruiter_smartphone_confirmed'  // Phase2-a: 募集人スマホ確認完了
    | 'customer_smartphone_confirmed'   // Phase2-a: お客様スマホ確認完了
    | 'paper_confirmation_completed'    // Phase2-a: 紙面確認完了
    | 'important_matters_delivery_confirmed' // Phase2-a: 重要事項説明書交付確認
    | 'recommended_plan_set'            // MS3: 推奨プラン設定
    | 'decided_plan_set'                // MS3: 決定プラン設定
    | 'plan_diff_reason_recorded'       // MS3: 差異理由記録
    | 'agency_report_generated'         // MS3: 代理店控え生成
    // Phase2-b-0: 種目横断共通イベント
    | 'insurance_category_selected'     // 上位5分類の選択
    | 'insurance_line_selected'         // 実種目（fire 等）の選択
    | 'contract_flow_selected'          // 契約フロー種別選択
    | 'case_phase_changed'              // 案件フェーズ遷移
    | 'property_profile_recorded'       // 対象物件プロファイル記録
    | 'ideal_coverage_diagnosed'        // あるべき補償像との差分診断
    | 'intent_inferred'                 // 推定意向の確定
    | 'intent_finalized'                // 最終意向の確定・合致確認
    | 'coverage_overlap_checked'        // 補償重複の確認

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
    // Phase2-a: G-28 面談シーンプリセット
    meeting_scene: MeetingScene | null
    // Phase2-a: G-27 電子的方法による提供への同意確認
    electronic_consent_status: ElectronicConsentStatus | null
    electronic_consent_method: ElectronicConsentMethod | null
    electronic_consent_confirmed_at: string | null
    electronic_consent_operator_id: string | null
    // Phase2-a: スマホ確認導線
    smartphone_conf_status: SmartphoneConfStatus
    recruiter_smartphone_confirmed_at: string | null
    customer_smartphone_confirmed_at: string | null
    // Phase2-a: 紙面確認
    paper_confirmation_status: PaperConfirmationStatus
    paper_confirmation_completed_at: string | null
    // Phase2-a: 重要事項説明書交付確認
    important_matters_delivered: boolean
    important_matters_delivered_at: string | null
    important_matters_delivery_method: ImportantMattersDeliveryMethod | null
    // Phase2-a: canNext制御
    can_next_blocked_reasons: string[]
    // Phase2-b-0: 種目横断共通基盤
    insurance_category_code: InsuranceCategoryCode | null
    insurance_line_code: InsuranceLineCode | null
    contract_flow_type: ContractFlowType | null
    diagnosis_baseline: DiagnosisBaseline | null
    case_phase: CasePhase
    // MS3: 推奨・決定プラン + 差異理由
    recommended_candidate_id: string | null
    decided_candidate_id: string | null
    plan_diff_reason: string | null
    plan_diff_reason_recorded_at: string | null
    customer_sheet_generated_at: string | null
    agency_report_generated_at: string | null
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
// Phase2-b-0 (MS1): Table Interfaces
// =============================================

export interface InsuranceCategory {
    code: InsuranceCategoryCode
    label_ja: string
    label_en: string
    supports_individual: boolean
    supports_corporate: boolean
    is_active: boolean
    sort_order: number
    created_at: string
    updated_at: string
}

export interface InsuranceLine {
    code: InsuranceLineCode
    category_code: InsuranceCategoryCode
    label_ja: string
    label_en: string
    milestone: string
    supports_individual: boolean
    supports_corporate: boolean
    is_implemented: boolean
    is_active: boolean
    sort_order: number
    created_at: string
    updated_at: string
}

export interface PropertyProfile {
    id: string
    run_id: string
    line_code: InsuranceLineCode
    municipality_code: string | null
    attributes: Record<string, unknown>
    created_at: string
    updated_at: string
}

export interface CoverageRuleMaster {
    id: string
    line_code: InsuranceLineCode
    coverage_code: string
    coverage_label_ja: string
    condition: Record<string, unknown>     // 物件属性へのマッチ条件（空 {} は無条件）
    tier: CoverageTier
    intent_dependent: boolean
    note: string | null
    sort_order: number
    is_active: boolean
    created_at: string
    updated_at: string
}

export interface FloodZoneMaster {
    municipality_code: string
    prefecture: string
    municipality_name: string
    flood_grade: number                    // 1-5
    source: string
    effective_from: string | null
    created_at: string
    updated_at: string
}

export interface IntentConfirmation {
    id: string
    run_id: string
    inferred_intent: Record<string, unknown>
    final_intent: Record<string, unknown>
    match_confirmed: boolean | null
    discrepancy_note: string | null
    overlap_check: Record<string, unknown>
    regulatory_basis: string
    confirmed_at: string | null
    confirmed_by: string | null
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

// Phase2-a: CSV Import Session Skeleton
export interface CsvImportSession {
    id: string
    run_id: string | null
    session_status: CsvImportSessionStatus
    filename: string | null
    row_count: number | null
    mapped_fields: Record<string, string>        // { csv_column: run_field }
    unmapped_fields: string[]
    manual_override_fields: string[]
    prior_contract_fields: Record<string, unknown>  // 前回契約データ
    new_contract_fields: Record<string, unknown>    // 今回契約データ
    error_detail: string | null
    created_at: string
    created_by: string | null
}

export type CsvImportSessionInsert = Omit<CsvImportSession, 'id' | 'created_at'>

// Phase2-a: Meeting scene → derived confirmation config
export interface MeetingSceneConfig {
    scene: MeetingScene
    smartphoneUsed: boolean           // スマホ確認導線を使うか
    recruiterInputMode: boolean       // 募集人入力モード（紙面確認時）
    electronicConsentRequired: boolean // 電子同意確認が必要か
    paperFallbackAllowed: boolean     // 紙面へのフォールバックを許可するか
}

// Derived config per scene (used in MS2 branching logic)
export const MEETING_SCENE_CONFIG: Record<MeetingScene, MeetingSceneConfig> = {
    visit_smartphone: {
        scene: 'visit_smartphone',
        smartphoneUsed: true,
        recruiterInputMode: false,
        electronicConsentRequired: true,
        paperFallbackAllowed: true,
    },
    visit_paper: {
        scene: 'visit_paper',
        smartphoneUsed: false,
        recruiterInputMode: true,
        electronicConsentRequired: false,
        paperFallbackAllowed: false,
    },
    pc_tablet: {
        scene: 'pc_tablet',
        smartphoneUsed: false,
        recruiterInputMode: false,
        electronicConsentRequired: true,
        paperFallbackAllowed: true,
    },
    telephone: {
        scene: 'telephone',
        smartphoneUsed: false,
        recruiterInputMode: true,
        electronicConsentRequired: false,
        paperFallbackAllowed: false,
    },
    web_meeting: {
        scene: 'web_meeting',
        smartphoneUsed: false,
        recruiterInputMode: false,
        electronicConsentRequired: true,
        paperFallbackAllowed: true,
    },
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
