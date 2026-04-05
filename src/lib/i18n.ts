// =============================================
// 日本語 / English i18n dictionary — M1 v4.1
// =============================================

export type Locale = 'ja' | 'en'

const dict = {
    ja: {
        // ── App chrome ────────────────────────────
        appTitle: '安心見える化™',
        appSubtitle: '選定支援システム',
        login: 'ログイン',
        logout: 'ログアウト',
        email: 'メールアドレス',
        password: 'パスワード',
        dashboard: 'ダッシュボード',
        newRun: '新規案件作成',
        runList: '案件一覧',

        // ── Run status (3 values per M1 v4.1) ─────
        status: 'ステータス',
        draft: '作成中',
        finalized: '確定済（編集不可）',
        archived: 'アーカイブ',

        // ── Customer / run basics ─────────────────
        customerType: '顧客区分',
        individual: '個人',
        corporate: '法人',
        customerRef: '顧客管理番号',
        runType: '案件種別',
        newContract: '新規契約',
        renewal: '更新・継続',
        testData: 'テストデータ',
        testDataNote: 'テストデータとしてマーク',

        // ── 5-Step wizard sidebar titles ──────────
        step1DiagnosisTitle: '現状確認・診断',
        step2IssueSharingTitle: '課題共有',
        step3IntentTitle: '基本意向確認',
        step4ScopeTitle: '比較範囲設定',
        step5PriorityTitle: '重視事項・重み付け',

        // ── customer_decision (4 values) ──────────
        decisionCompare: '比較して選ぶ',
        decisionRenewalNoChange: '前年同条件更改（比較省略）',
        decisionInformationRefused: '情報提供拒否（診断不希望）',
        decisionComparisonWaived: '比較説明省略（顧客同意済み）',

        // ── compliance_mode (2 values) ────────────
        complianceMode: '法令類型',
        complianceFull: 'フル比較（完全履行）',
        complianceException: '例外処理（省略経路）',

        // ── comparison_scope ──────────────────────
        comparisonScope: '比較範囲',
        comparisonScopeMemo: '比較範囲メモ',
        scopeSameInsurer: '同一保険会社内比較',
        scopeMultiInsurer: '複数保険会社比較',

        // ── export_status ─────────────────────────
        exportPending: '生成待ち',
        exportGenerating: '生成中',
        exportCompleted: '生成完了',
        exportDelivered: '交付済',
        exportFailed: '生成失敗',

        // ── Step 1 fields ─────────────────────────
        snapshotCsvImported: 'CSVデータ取込済',
        snapshotPdfKey: '証券PDF',
        missingFlags: '不足フラグ',
        uncertainFlags: '不確定フラグ（Fail-Closed）',
        confirmedItems: '確認済み項目',
        supplementedItems: '補完済み項目',
        unresolvedItems: '未解決項目',
        reviewedBy: '確認担当者',
        reviewedAt: '確認日時',
        markConfirmed: '確認済みにする',
        markSupplemented: '補完済みにする',
        completeReview: '確認完了・次へ',

        // ── Step 2 fields ─────────────────────────
        diagnosisMemo: '診断メモ（監査用）',
        shareIssues: '課題を共有して次へ',

        // ── Step 3 fields ─────────────────────────
        customerIntentMemo: '意向まとめ（メモ）',
        customerDecisionAt: '顧客判断日時',

        // ── Step 5 fields ─────────────────────────
        priorityFactors: '重視事項',
        priorityWeight: '重み付け（1〜5）',
        premium: '保険料',
        coverage: '補償内容',
        deductible: '免責金額',
        service: 'サービス',
        claimsHandling: '事故対応',
        paymentRecord: '支払実績',
        priorityWeightError: '重み付けのキーは重視事項に含まれるもののみ設定できます',

        // ── Comparison screen ─────────────────────
        comparison: '比較画面',
        beginPresenting: '提示を開始する',
        comparePresentedAt: '比較提示日時',
        insurerListPresented: '保険会社リスト提示済',
        candidates: '比較候補',
        addCandidate: '候補を追加',
        excludeCandidate: '候補を除外',
        excludeReason: '除外理由',
        currentContract: '現契約',
        candidateLabel: '候補',
        insurerName: '保険会社名',
        productName: '商品名',
        annualPremium: '年間保険料（円）',
        slotNo: '候補No.',

        // ── Finalize tab ──────────────────────────
        finalize: '確定',
        finalizeTab: '案件確定',
        finalizeBlocked: '未解決の項目があるため確定できません',
        finalizePreflightTitle: '確定前チェック',
        preflightUnresolvedItems: '未解決項目なし',
        preflightDecisionSet: '顧客判断が設定されています',
        preflightCandidatesExist: '有効な候補が1件以上あります',
        preflightComparePresented: '比較提示が完了しています',
        consentImportantMatters: '重要事項説明への同意',
        consentPersonalInfo: '個人情報取扱への同意',
        consentComparisonResult: '比較結果説明への同意',
        minimalProofPdf: '簡易証明PDF（例外経路）',
        finalizeConfirmTitle: '案件を確定しますか？',
        finalizeConfirmBody: '確定後は原則として編集できません。内容をよく確認してください。',
        finalizeSuccess: '案件を確定しました',
        finalizeFailed: '確定処理に失敗しました',

        // ── Audit event type labels (11 values) ───
        eventIssueShared: '課題共有',
        eventManualReviewCompleted: '手動確認完了',
        eventInsurerListPresented: '保険会社リスト提示',
        eventCustomerIntentConfirmed: '意向確認',
        eventComparePresented: '比較提示',
        eventExclusionReasonRecorded: '除外理由記録',
        eventComparisonWaiverConfirmed: '比較放棄確認',
        eventConsentImportantMatters: '重要事項同意',
        eventConsentPersonalInfo: '個人情報同意',
        eventConsentComparisonResult: '比較結果同意',
        eventRunFinalized: '案件確定',

        // ── Overview / detail fields ──────────────
        basicInfo: '基本情報',
        runDetails: '案件詳細',
        overview: '概要',
        auditLog: '監査ログ',
        operatorName: '担当者名',
        archiveRun: 'アーカイブ',
        archiveConfirm: 'この案件をアーカイブしますか？',

        // ── Common UI ────────────────────────────
        save: '保存',
        next: '次へ',
        back: '戻る',
        confirm: '確認',
        edit: '編集',
        add: '追加',
        close: '閉じる',
        search: '検索',
        filter: 'フィルター',
        all: 'すべて',
        active: '有効',
        excluded: '除外',
        required: '必須',
        optional: '任意',
        missing: '補償なし',
        uncertain: '確定不能',
        fieldRequired: 'この項目は必須です',
        minChars: '15文字以上入力してください',
        language: '言語',
        noDataFound: 'データがありません',
        loading: '読み込み中...',
        error: 'エラー',
        retry: '再試行',
        success: '成功',
        createdAt: '作成日時',
        updatedAt: '更新日時',
        finalizedAt: '確定日時',
        loginError: 'ログインに失敗しました',
        welcomeBack: 'おかえりなさい',
        loginSubtitle: 'アカウント情報を入力してください',
    },
    en: {
        // ── App chrome ────────────────────────────
        appTitle: 'InsureVision™',
        appSubtitle: 'Selection Support System',
        login: 'Login',
        logout: 'Logout',
        email: 'Email',
        password: 'Password',
        dashboard: 'Dashboard',
        newRun: 'Create New Case',
        runList: 'Case List',

        // ── Run status ────────────────────────────
        status: 'Status',
        draft: 'Draft',
        finalized: 'Confirmed (Read-only)',
        archived: 'Archived',

        // ── Customer / run basics ─────────────────
        customerType: 'Customer Type',
        individual: 'Individual',
        corporate: 'Corporate',
        customerRef: 'Customer Reference',
        runType: 'Case Type',
        newContract: 'New Contract',
        renewal: 'Renewal',
        testData: 'Test Data',
        testDataNote: 'Mark as test data',

        // ── 5-Step wizard sidebar titles ──────────
        step1DiagnosisTitle: 'Current Status & Diagnosis',
        step2IssueSharingTitle: 'Issue Sharing',
        step3IntentTitle: 'Basic Intent',
        step4ScopeTitle: 'Comparison Scope',
        step5PriorityTitle: 'Priority Factors',

        // ── customer_decision ─────────────────────
        decisionCompare: 'Compare & Choose',
        decisionRenewalNoChange: 'Renew — No Change (Skip Comparison)',
        decisionInformationRefused: 'Information Refused',
        decisionComparisonWaived: 'Comparison Explanation Waived (Customer Consent)',

        // ── compliance_mode ───────────────────────
        complianceMode: 'Compliance Mode',
        complianceFull: 'Full Comparison (Complete)',
        complianceException: 'Exception Route',

        // ── comparison_scope ──────────────────────
        comparisonScope: 'Comparison Scope',
        comparisonScopeMemo: 'Scope Notes',
        scopeSameInsurer: 'Same Insurer (In-house Plan Comparison)',
        scopeMultiInsurer: 'Multi-Insurer (Cross-company Comparison)',

        // ── export_status ─────────────────────────
        exportPending: 'Pending',
        exportGenerating: 'Generating',
        exportCompleted: 'Completed',
        exportDelivered: 'Delivered',
        exportFailed: 'Failed',

        // ── Step 1 fields ─────────────────────────
        snapshotCsvImported: 'CSV Data Imported',
        snapshotPdfKey: 'Policy PDF',
        missingFlags: 'Missing Flags',
        uncertainFlags: 'Uncertain Flags (Fail-Closed)',
        confirmedItems: 'Confirmed Items',
        supplementedItems: 'Supplemented Items',
        unresolvedItems: 'Unresolved Items',
        reviewedBy: 'Reviewed By',
        reviewedAt: 'Review Date/Time',
        markConfirmed: 'Mark as Confirmed',
        markSupplemented: 'Mark as Supplemented',
        completeReview: 'Complete Review & Next',

        // ── Step 2 fields ─────────────────────────
        diagnosisMemo: 'Diagnosis Memo (Audit)',
        shareIssues: 'Share Issues & Next',

        // ── Step 3 fields ─────────────────────────
        customerIntentMemo: 'Intent Summary (Memo)',
        customerDecisionAt: 'Decision Date/Time',

        // ── Step 5 fields ─────────────────────────
        priorityFactors: 'Priority Factors',
        priorityWeight: 'Priority Weight (1–5)',
        premium: 'Premium',
        coverage: 'Coverage',
        deductible: 'Deductible',
        service: 'Service',
        claimsHandling: 'Claims Handling',
        paymentRecord: 'Payment Record',
        priorityWeightError: 'Priority weight keys must be a subset of priority factors',

        // ── Comparison screen ─────────────────────
        comparison: 'Comparison',
        beginPresenting: 'Begin Presenting to Customer',
        comparePresentedAt: 'Comparison Presented At',
        insurerListPresented: 'Insurer List Presented',
        candidates: 'Candidates',
        addCandidate: 'Add Candidate',
        excludeCandidate: 'Exclude',
        excludeReason: 'Exclusion Reason',
        currentContract: 'Current Contract',
        candidateLabel: 'Candidate',
        insurerName: 'Insurance Company',
        productName: 'Product Name',
        annualPremium: 'Annual Premium (¥)',
        slotNo: 'Slot No.',

        // ── Finalize tab ──────────────────────────
        finalize: 'Finalize',
        finalizeTab: 'Finalize Case',
        finalizeBlocked: 'Cannot finalize — unresolved items remain',
        finalizePreflightTitle: 'Pre-flight Checklist',
        preflightUnresolvedItems: 'No unresolved items',
        preflightDecisionSet: 'Customer decision is set',
        preflightCandidatesExist: 'At least one active candidate exists',
        preflightComparePresented: 'Comparison has been presented',
        consentImportantMatters: 'Consent — Important Matters',
        consentPersonalInfo: 'Consent — Personal Information',
        consentComparisonResult: 'Consent — Comparison Result',
        minimalProofPdf: 'Minimal Proof PDF (Exception Route)',
        finalizeConfirmTitle: 'Finalize this case?',
        finalizeConfirmBody: 'Editing is restricted after finalization. Please review carefully.',
        finalizeSuccess: 'Case finalized successfully',
        finalizeFailed: 'Finalization failed',

        // ── Audit event type labels ───────────────
        eventIssueShared: 'Issue Shared',
        eventManualReviewCompleted: 'Manual Review Completed',
        eventInsurerListPresented: 'Insurer List Presented',
        eventCustomerIntentConfirmed: 'Intent Confirmed',
        eventComparePresented: 'Comparison Presented',
        eventExclusionReasonRecorded: 'Exclusion Reason Recorded',
        eventComparisonWaiverConfirmed: 'Comparison Waiver Confirmed',
        eventConsentImportantMatters: 'Consent: Important Matters',
        eventConsentPersonalInfo: 'Consent: Personal Info',
        eventConsentComparisonResult: 'Consent: Comparison Result',
        eventRunFinalized: 'Case Finalized',

        // ── Overview / detail ─────────────────────
        basicInfo: 'Basic Info',
        runDetails: 'Case Details',
        overview: 'Overview',
        auditLog: 'Audit Log',
        operatorName: 'Operator',
        archiveRun: 'Archive',
        archiveConfirm: 'Archive this case?',

        // ── Common UI ────────────────────────────
        save: 'Save',
        next: 'Next',
        back: 'Back',
        confirm: 'Confirm',
        edit: 'Edit',
        add: 'Add',
        close: 'Close',
        search: 'Search',
        filter: 'Filter',
        all: 'All',
        active: 'Active',
        excluded: 'Excluded',
        required: 'Required',
        optional: 'Optional',
        missing: 'Missing',
        uncertain: 'Uncertain',
        fieldRequired: 'This field is required',
        minChars: 'Enter at least 15 characters',
        language: 'Language',
        noDataFound: 'No data found',
        loading: 'Loading...',
        error: 'Error',
        retry: 'Retry',
        success: 'Success',
        createdAt: 'Created At',
        updatedAt: 'Updated At',
        finalizedAt: 'Finalized At',
        loginError: 'Login failed',
        welcomeBack: 'Welcome back',
        loginSubtitle: 'Enter your credentials',
    },
} as const

export type DictKey = keyof typeof dict.ja

export function t(locale: Locale, key: DictKey): string {
    return dict[locale]?.[key] ?? dict.ja[key] ?? key
}

export function getDict(locale: Locale) {
    return dict[locale] ?? dict.ja
}
