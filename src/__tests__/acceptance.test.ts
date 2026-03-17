/**
 * InsureVision M1 v4.1 — Acceptance Tests TC1–TC11
 *
 * These tests cover the pure-logic layer only (no DB, no HTTP server).
 * They verify the spec's critical invariants: Fail-Closed behaviour,
 * audit-event fire rules, validation gates, and PDF stub content.
 */

import { describe, it, expect } from 'vitest'

// ─────────────────────────────────────────────────────────────────────────────
// Helpers — minimal stubs that mirror prod interfaces
// ─────────────────────────────────────────────────────────────────────────────

import type {
    CustomerDecision,
    RunType,
    AuditEventType,
    Run,
    Snapshot,
    SnapshotFlag,
    MinimalProofPdfStub,
} from '@/lib/types'

import { getMissingGuideMessage, getUncertainGuideMessage } from '@/lib/flagGuides'
import { t } from '@/lib/i18n'

// ── Minimal proof stub builder (extracted from api/finalize/route.ts) ──
function buildMinimalProofStub(
    run: Partial<Run> & { id: string; customer_ref: string; customer_decision: CustomerDecision; customer_intent_memo: string | null; operator_id: string; compare_presented_at?: string | null },
    snapshot: Partial<Snapshot> | null,
    consentFlags: { comparison_result: boolean; important_matters: boolean; personal_info: boolean }
): MinimalProofPdfStub & Record<string, unknown> {
    const stub: MinimalProofPdfStub & Record<string, unknown> = {
        run_id: run.id,
        customer_ref: run.customer_ref,
        operator_name: run.operator_id,
        generated_at: new Date().toISOString(),
        customer_decision: run.customer_decision,
        decision_reason: run.customer_intent_memo ?? '',
        insurer_list_presented: true,
    }

    if (run.customer_decision === 'comparison_waived') {
        stub.consent_important_matters = consentFlags.important_matters
        stub.consent_personal_info = consentFlags.personal_info
    }

    if (run.customer_decision === 'compare') {
        stub.consent_comparison_result = consentFlags.comparison_result
    }

    if (snapshot) {
        stub.confirmed_items = snapshot.confirmed_items
        stub.supplemented_items = snapshot.supplemented_items
        stub.core_logic_version = snapshot.core_logic_version
    }

    return stub
}

// ── Finalize pre-flight validator (mirrors /api/finalize route logic) ──
interface FinalizeInput {
    run: { run_status: string; customer_decision?: string | null; compare_presented_at?: string | null }
    snapshot: { unresolved_items: string[] } | null
    exceptionRoute: boolean
}

function validateFinalizeRequest(input: FinalizeInput): { ok: boolean; status: number; error?: string; items?: string[] } {
    const { run, snapshot, exceptionRoute } = input

    if (run.run_status !== 'draft') {
        return { ok: false, status: 400, error: 'already finalized' }
    }

    if (snapshot && snapshot.unresolved_items.length > 0) {
        return { ok: false, status: 422, error: 'unresolved_items', items: snapshot.unresolved_items }
    }

    if (!exceptionRoute && !run.compare_presented_at) {
        return { ok: false, status: 422, error: 'compare_presented_at not set' }
    }

    return { ok: true, status: 200 }
}

// ── Wizard Step3 — builds the event batch (mirrors page.tsx createRunAndFireEvents) ──
function buildAuditEventBatch(
    runId: string,
    operatorId: string,
    step1Data: { confirmedItems: string[]; supplementedItems: string[]; unresolvedItems: string[] },
    diagnosisMemo: string,
    intentData: { customerDecision: CustomerDecision; customerIntentMemo: string; consentState: { importantMatters: boolean; personalInfo: boolean } }
): Array<{ event_type: AuditEventType; payload: Record<string, unknown> }> {
    const events: Array<{ event_type: AuditEventType; payload: Record<string, unknown> }> = [
        {
            event_type: 'manual_review_completed',
            payload: {
                confirmed_items: step1Data.confirmedItems,
                supplemented_items: step1Data.supplementedItems,
                unresolved_items: step1Data.unresolvedItems,
            },
        },
        {
            event_type: 'issue_shared',
            payload: { diagnosis_memo: diagnosisMemo },
        },
        // insurer_list_presented auto-fires at Step2→3 transition for ALL paths
        {
            event_type: 'insurer_list_presented',
            payload: { auto_recorded: true },
        },
        {
            event_type: 'customer_intent_confirmed',
            payload: { decision: intentData.customerDecision, memo: intentData.customerIntentMemo },
        },
    ]

    if (intentData.customerDecision === 'comparison_waived') {
        events.push({
            event_type: 'comparison_waiver_confirmed',
            payload: {
                consent_important_matters: intentData.consentState.importantMatters,
                consent_personal_info: intentData.consentState.personalInfo,
            },
        })
    }

    return events
}

// ── Step3Intent availability — mirrors wizard filter logic ──
function availableDecisions(runType: RunType): CustomerDecision[] {
    const all: CustomerDecision[] = ['compare', 'renewal_no_change', 'information_refused', 'comparison_waived']
    return all.filter(d => d !== 'renewal_no_change' || runType === 'renewal')
}

// ── Step5 priority_weight validation (mirrors Step5Priority handleComplete) ──
function validatePriorityWeight(
    priorityFactors: string[],
    priorityWeight: Record<string, number>
): { valid: boolean; invalidKeys: string[]; missingWeights: string[] } {
    const weightKeys = Object.keys(priorityWeight)
    const invalidKeys = weightKeys.filter(k => !priorityFactors.includes(k))
    const missingWeights = priorityFactors.filter(k => !priorityWeight[k])
    return { valid: invalidKeys.length === 0 && missingWeights.length === 0, invalidKeys, missingWeights }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC1: insurer_list_presented fires for ALL customer_decision paths
// including information_refused (the TC4 edge case in the spec)
// ─────────────────────────────────────────────────────────────────────────────
describe('TC1 — insurer_list_presented fires for all decision paths', () => {
    const decisions: CustomerDecision[] = ['compare', 'renewal_no_change', 'information_refused', 'comparison_waived']

    it.each(decisions)('decision=%s → batch contains insurer_list_presented', (decision) => {
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            { confirmedItems: [], supplementedItems: [], unresolvedItems: [] },
            'テスト診断メモ（15文字以上）',
            { customerDecision: decision, customerIntentMemo: 'テスト意向メモ（15文字以上）', consentState: { importantMatters: true, personalInfo: true } }
        )

        const types = batch.map(e => e.event_type)
        expect(types).toContain('insurer_list_presented')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC2: renewal_no_change is only available for renewal run_type
// ─────────────────────────────────────────────────────────────────────────────
describe('TC2 — renewal_no_change availability by run_type', () => {
    it('new_contract → renewal_no_change NOT available', () => {
        const options = availableDecisions('new_contract')
        expect(options).not.toContain('renewal_no_change')
        expect(options).toContain('compare')
        expect(options).toContain('information_refused')
        expect(options).toContain('comparison_waived')
    })

    it('renewal → renewal_no_change IS available', () => {
        const options = availableDecisions('renewal')
        expect(options).toContain('renewal_no_change')
        expect(options).toHaveLength(4)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC3: comparison_waived path fires comparison_waiver_confirmed event
// and normal paths do NOT fire it
// ─────────────────────────────────────────────────────────────────────────────
describe('TC3 — comparison_waiver_confirmed event fires only for comparison_waived', () => {
    it('comparison_waived → batch includes comparison_waiver_confirmed with consent payload', () => {
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            { confirmedItems: [], supplementedItems: [], unresolvedItems: [] },
            'テスト診断メモ（15文字以上）',
            {
                customerDecision: 'comparison_waived',
                customerIntentMemo: 'テスト意向メモ（15文字以上）',
                consentState: { importantMatters: true, personalInfo: true },
            }
        )

        const waiverEvent = batch.find(e => e.event_type === 'comparison_waiver_confirmed')
        expect(waiverEvent).toBeDefined()
        expect(waiverEvent?.payload.consent_important_matters).toBe(true)
        expect(waiverEvent?.payload.consent_personal_info).toBe(true)
    })

    it('compare → batch does NOT include comparison_waiver_confirmed', () => {
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            { confirmedItems: [], supplementedItems: [], unresolvedItems: [] },
            'テスト診断メモ（15文字以上）',
            {
                customerDecision: 'compare',
                customerIntentMemo: 'テスト意向メモ（15文字以上）',
                consentState: { importantMatters: false, personalInfo: false },
            }
        )

        const types = batch.map(e => e.event_type)
        expect(types).not.toContain('comparison_waiver_confirmed')
    })

    it.each(['renewal_no_change', 'information_refused'] as CustomerDecision[])(
        'decision=%s → no comparison_waiver_confirmed',
        (decision) => {
            const batch = buildAuditEventBatch(
                'run-001', 'op-001',
                { confirmedItems: [], supplementedItems: [], unresolvedItems: [] },
                'テスト診断メモ（15文字以上）',
                {
                    customerDecision: decision,
                    customerIntentMemo: 'テスト意向メモ（15文字以上）',
                    consentState: { importantMatters: false, personalInfo: false },
                }
            )

            const types = batch.map(e => e.event_type)
            expect(types).not.toContain('comparison_waiver_confirmed')
        }
    )
})

// ─────────────────────────────────────────────────────────────────────────────
// TC4: information_refused batch structure — specific items from spec
// ─────────────────────────────────────────────────────────────────────────────
describe('TC4 — information_refused audit event batch is correct', () => {
    it('batch contains exactly manual_review_completed, issue_shared, insurer_list_presented, customer_intent_confirmed', () => {
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            { confirmedItems: [], supplementedItems: [], unresolvedItems: [] },
            'テスト診断メモ（15文字以上）',
            {
                customerDecision: 'information_refused',
                customerIntentMemo: 'テスト意向メモ（15文字以上）',
                consentState: { importantMatters: false, personalInfo: false },
            }
        )

        const types = batch.map(e => e.event_type)
        expect(types).toEqual([
            'manual_review_completed',
            'issue_shared',
            'insurer_list_presented',
            'customer_intent_confirmed',
        ])
    })

    it('customer_intent_confirmed payload carries decision=information_refused', () => {
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            { confirmedItems: [], supplementedItems: [], unresolvedItems: [] },
            'テスト診断メモ（15文字以上）',
            {
                customerDecision: 'information_refused',
                customerIntentMemo: '顧客が情報提供を拒否しました（テストメモ）',
                consentState: { importantMatters: false, personalInfo: false },
            }
        )

        const intentEvt = batch.find(e => e.event_type === 'customer_intent_confirmed')
        expect(intentEvt?.payload.decision).toBe('information_refused')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC5: Fail-Closed — uncertain flags with unresolved_items block finalize
// ─────────────────────────────────────────────────────────────────────────────
describe('TC5 — Fail-Closed: unresolved_items blocks finalize', () => {
    it('unresolved_items non-empty → validateFinalizeRequest returns 422', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'compare', compare_presented_at: '2026-01-01T00:00:00Z' },
            snapshot: { unresolved_items: ['option_c_flag'] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(false)
        expect(result.status).toBe(422)
        expect(result.error).toBe('unresolved_items')
        expect(result.items).toContain('option_c_flag')
    })

    it('unresolved_items empty → passes Fail-Closed gate', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'compare', compare_presented_at: '2026-01-01T00:00:00Z' },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(true)
    })

    it('no snapshot → Fail-Closed gate passes (nothing to block on)', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'information_refused' },
            snapshot: null,
            exceptionRoute: true,
        })

        expect(result.ok).toBe(true)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC6: customerIntentMemo min-15-chars validation
// ─────────────────────────────────────────────────────────────────────────────
describe('TC6 — customerIntentMemo minimum 15 characters', () => {
    const validate = (memo: string) => memo.trim().length >= 15

    it('14 chars → invalid', () => {
        expect(validate('12345678901234')).toBe(false)
    })

    it('15 chars → valid', () => {
        expect(validate('123456789012345')).toBe(true)
    })

    it('Japanese char counts respected', () => {
        expect(validate('顧客が比較して選ぶことを希望')).toBe(false)   // 14 chars — invalid
        expect(validate('顧客が比較して選ぶことを強く希望')).toBe(true)  // 15 chars — valid
    })

    it('whitespace-only is invalid regardless of length', () => {
        expect(validate('               ')).toBe(false)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC7: priority_weight keys must be strict subset of priority_factors
// ─────────────────────────────────────────────────────────────────────────────
describe('TC7 — priority_weight key-subset validation', () => {
    it('weight keys ⊆ factors → valid', () => {
        const result = validatePriorityWeight(
            ['premium', 'coverage_amount', 'rider_options'],
            { premium: 5, coverage_amount: 3, rider_options: 4 }
        )
        expect(result.valid).toBe(true)
        expect(result.invalidKeys).toHaveLength(0)
    })

    it('weight key not in factors → invalid', () => {
        const result = validatePriorityWeight(
            ['premium', 'coverage_amount'],
            { premium: 5, coverage_amount: 3, insurer_reputation: 2 }
        )
        expect(result.valid).toBe(false)
        expect(result.invalidKeys).toContain('insurer_reputation')
    })

    it('factor without weight → invalid (missing weight)', () => {
        const result = validatePriorityWeight(
            ['premium', 'coverage_amount'],
            { premium: 5 }   // coverage_amount missing
        )
        expect(result.valid).toBe(false)
        expect(result.missingWeights).toContain('coverage_amount')
    })

    it('empty factors with empty weights → valid', () => {
        // Edge case: user selects no factors (caught earlier by "min 1 factor" gate)
        const result = validatePriorityWeight([], {})
        expect(result.valid).toBe(true)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC8: run already finalized → finalize returns 400
// ─────────────────────────────────────────────────────────────────────────────
describe('TC8 — double-finalize blocked (idempotency)', () => {
    it('run_status=finalized → returns 400 already finalized', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'finalized', customer_decision: 'compare', compare_presented_at: '2026-01-01T00:00:00Z' },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(false)
        expect(result.status).toBe(400)
        expect(result.error).toBe('already finalized')
    })

    it('run_status=archived → returns 400', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'archived' },
            snapshot: null,
            exceptionRoute: false,
        })

        expect(result.ok).toBe(false)
        expect(result.status).toBe(400)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC9: compare path requires compare_presented_at (normal route)
// ─────────────────────────────────────────────────────────────────────────────
describe('TC9 — compare path requires compare_presented_at', () => {
    it('normal route, compare_presented_at not set → 422', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'compare', compare_presented_at: null },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(false)
        expect(result.status).toBe(422)
        expect(result.error).toBe('compare_presented_at not set')
    })

    it('exception route — compare_presented_at NOT required', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'renewal_no_change', compare_presented_at: null },
            snapshot: { unresolved_items: [] },
            exceptionRoute: true,
        })

        expect(result.ok).toBe(true)
    })

    it('compare path + compare_presented_at set → passes', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'compare', compare_presented_at: '2026-03-17T10:00:00Z' },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(true)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC10: unresolved_items blocks finalize regardless of manual_review_completed
// (TC11 in spec — recording manual_review_completed ≠ clearing Fail-Closed gate)
// ─────────────────────────────────────────────────────────────────────────────
describe('TC10 — manual_review_completed event does NOT clear Fail-Closed gate', () => {
    it('manual_review_completed in batch but unresolved_items still non-empty → finalize still blocked', () => {
        // Step 1: build event batch (manual_review_completed is recorded)
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            {
                confirmedItems: ['option_a'],
                supplementedItems: [],
                unresolvedItems: ['option_c_flag'],   // still unresolved
            },
            'テスト診断メモ（15文字以上）',
            {
                customerDecision: 'compare',
                customerIntentMemo: 'テスト意向メモ（15文字以上）',
                consentState: { importantMatters: false, personalInfo: false },
            }
        )

        // Confirm manual_review_completed IS in the batch
        const reviewEvt = batch.find(e => e.event_type === 'manual_review_completed')
        expect(reviewEvt).toBeDefined()
        expect(reviewEvt?.payload.unresolved_items).toContain('option_c_flag')

        // But the finalize gate checks snapshot.unresolved_items independently
        const finalizeResult = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'compare', compare_presented_at: '2026-03-17T10:00:00Z' },
            snapshot: { unresolved_items: ['option_c_flag'] },   // still blocked
            exceptionRoute: false,
        })

        expect(finalizeResult.ok).toBe(false)
        expect(finalizeResult.status).toBe(422)
        expect(finalizeResult.items).toContain('option_c_flag')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC11: MinimalProofPdfStub content is correct per decision path
// ─────────────────────────────────────────────────────────────────────────────
describe('TC11 — MinimalProofPdfStub content per decision path', () => {
    const baseRun = {
        id: 'run-abc',
        customer_ref: 'C-2026-0001',
        operator_id: 'op-001',
        customer_intent_memo: '顧客が情報提供を拒否しました（テストメモ）',
    }

    it('insurer_list_presented is always true (all paths)', () => {
        const decisions: CustomerDecision[] = ['compare', 'renewal_no_change', 'information_refused', 'comparison_waived']
        decisions.forEach(decision => {
            const stub = buildMinimalProofStub(
                { ...baseRun, customer_decision: decision },
                null,
                { comparison_result: false, important_matters: false, personal_info: false }
            )
            expect(stub.insurer_list_presented).toBe(true)
        })
    })

    it('compare path → stub includes consent_comparison_result, NOT consent_important_matters/personal_info', () => {
        const stub = buildMinimalProofStub(
            { ...baseRun, customer_decision: 'compare', compare_presented_at: '2026-03-17T10:00:00Z' },
            null,
            { comparison_result: true, important_matters: false, personal_info: false }
        )

        expect(stub.consent_comparison_result).toBe(true)
        expect(stub.consent_important_matters).toBeUndefined()
        expect(stub.consent_personal_info).toBeUndefined()
    })

    it('comparison_waived path → stub includes consent_important_matters and consent_personal_info', () => {
        const stub = buildMinimalProofStub(
            { ...baseRun, customer_decision: 'comparison_waived' },
            null,
            { comparison_result: false, important_matters: true, personal_info: true }
        )

        expect(stub.consent_important_matters).toBe(true)
        expect(stub.consent_personal_info).toBe(true)
        expect(stub.consent_comparison_result).toBeUndefined()
    })

    it('information_refused path → minimal stub (no consent fields)', () => {
        const stub = buildMinimalProofStub(
            { ...baseRun, customer_decision: 'information_refused' },
            null,
            { comparison_result: false, important_matters: false, personal_info: false }
        )

        expect(stub.customer_decision).toBe('information_refused')
        expect(stub.consent_comparison_result).toBeUndefined()
        expect(stub.consent_important_matters).toBeUndefined()
    })

    it('snapshot data merged into stub when provided', () => {
        const snapshot: Partial<Snapshot> = {
            confirmed_items: ['option_a'],
            supplemented_items: ['option_b'],
            unresolved_items: [],
            core_logic_version: '1.0.0',
        }

        const stub = buildMinimalProofStub(
            { ...baseRun, customer_decision: 'information_refused' },
            snapshot,
            { comparison_result: false, important_matters: false, personal_info: false }
        )

        expect(stub.confirmed_items).toEqual(['option_a'])
        expect(stub.supplemented_items).toEqual(['option_b'])
        expect(stub.core_logic_version).toBe('1.0.0')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// Bonus: flagGuides and i18n sanity checks
// ─────────────────────────────────────────────────────────────────────────────
describe('Flag guide messages', () => {
    it('getMissingGuideMessage returns ja message for known key', () => {
        const msg = getMissingGuideMessage('option_a', 'ja')
        expect(msg).toContain('比較項目A')
        expect(msg.length).toBeGreaterThan(10)
    })

    it('getMissingGuideMessage returns en message for known key', () => {
        const msg = getMissingGuideMessage('option_a', 'en')
        expect(msg).toContain('Option A')
    })

    it('getUncertainGuideMessage includes Fail-Closed for known key', () => {
        const msg = getUncertainGuideMessage('option_c_flag', 'ja')
        expect(msg).toContain('Fail-Closed')
    })

    it('getMissingGuideMessage returns generic fallback for unknown key', () => {
        const msg = getMissingGuideMessage('unknown_xyz', 'en')
        expect(msg).toContain('unknown_xyz')
    })

    it('getUncertainGuideMessage returns generic fallback for unknown key', () => {
        const msg = getUncertainGuideMessage('ghost_flag', 'ja')
        expect(msg).toContain('ghost_flag')
        expect(msg).toContain('Fail-Closed')
    })
})

describe('i18n translation function', () => {
    it('returns Japanese string for ja locale', () => {
        expect(t('ja', 'draft')).toBe('作成中')
        expect(t('ja', 'finalized')).toBe('確定済')
        expect(t('ja', 'archived')).toBe('アーカイブ')
    })

    it('returns English string for en locale', () => {
        expect(t('en', 'draft')).toBe('Draft')
        expect(t('en', 'finalized')).toBe('Finalized')
        expect(t('en', 'archived')).toBe('Archived')
    })

    it('all 4 customer_decision labels are defined in both locales', () => {
        const decisions = ['decisionCompare', 'decisionRenewalNoChange', 'decisionInformationRefused', 'decisionComparisonWaived'] as const
        decisions.forEach(key => {
            expect(t('ja', key).length).toBeGreaterThan(0)
            expect(t('en', key).length).toBeGreaterThan(0)
        })
    })

    it('all 11 audit event type labels are defined in both locales', () => {
        const eventKeys = [
            'eventIssueShared', 'eventManualReviewCompleted', 'eventInsurerListPresented',
            'eventCustomerIntentConfirmed', 'eventComparePresented', 'eventExclusionReasonRecorded',
            'eventComparisonWaiverConfirmed', 'eventConsentImportantMatters', 'eventConsentPersonalInfo',
            'eventConsentComparisonResult', 'eventRunFinalized',
        ] as const
        eventKeys.forEach(key => {
            expect(t('ja', key).length).toBeGreaterThan(0)
            expect(t('en', key).length).toBeGreaterThan(0)
        })
    })

    it('step titles defined for all 5 steps', () => {
        const stepKeys = ['step1DiagnosisTitle', 'step2IssueSharingTitle', 'step3IntentTitle', 'step4ScopeTitle', 'step5PriorityTitle'] as const
        stepKeys.forEach(key => {
            expect(t('ja', key).length).toBeGreaterThan(0)
            expect(t('en', key).length).toBeGreaterThan(0)
        })
    })
})
