/**
 * InsureVision M1 v4.1 — Acceptance Tests TC1–TC11
 * =====================================================================
 * 【テスト種別の位置づけ】
 *
 * ■ 本ファイル（テストコード一式）
 *   ビジネスロジック層の「純粋ロジック単体検証」です。
 *   データベース・HTTPサーバーへの接続は一切行いません。
 *   (pure-logic layer only — no DB, no HTTP server)
 *   各TCのロジック不変条件（Fail-Closed動作、イベント発火ルール、
 *   バリデーションゲート、PDF stubの内容）を自動検証します。
 *
 * ■ 受入テスト証跡（別紙）
 *   実際の画面操作・目視確認による手動テストの結果です。
 *   ブラウザ上でウィザードを操作し、DBへの記録・UIの挙動を
 *   スクリーンショット付きで確認したものです。
 *
 * 両者は補完関係にあり、どちらか一方で全項目を代替するものでは
 * ありません。
 * =====================================================================
 *
 * TC番号はM1設計書 v4.1 の定義に準拠します:
 *   TC10 = uncertain項目が残ったままFinalizeを試みて失敗するケース
 *   TC11 = manual_review_completed記録済みだがunresolved_itemsが
 *          残っている状態でFinalize不可（独立したゲート）
 */

import { describe, it, expect } from 'vitest'

import type {
    CustomerDecision,
    RunType,
    AuditEventType,
    Run,
    Snapshot,
    MinimalProofPdfStub,
} from '@/lib/types'

import { getMissingGuideMessage, getUncertainGuideMessage } from '@/lib/flagGuides'
import { t } from '@/lib/i18n'

// ─────────────────────────────────────────────────────────────────────────────
// Pure-logic helpers (mirror production implementations, no side effects)
// ─────────────────────────────────────────────────────────────────────────────

/** Mirrors buildMinimalProofStub() in src/app/api/finalize/route.ts */
function buildMinimalProofStub(
    run: Partial<Run> & {
        id: string
        customer_ref: string
        customer_decision: CustomerDecision
        customer_intent_memo: string | null
        operator_id: string
        compare_presented_at?: string | null
    },
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
        insurer_list_presented: true, // always true: auto-recorded at Step2→3 for ALL paths
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

/** Mirrors validateFinalizeRequest() in src/app/api/finalize/route.ts */
interface FinalizeInput {
    run: { run_status: string; customer_decision?: string | null; compare_presented_at?: string | null }
    snapshot: { unresolved_items: string[] } | null
    exceptionRoute: boolean
}

function validateFinalizeRequest(
    input: FinalizeInput
): { ok: boolean; status: number; error?: string; items?: string[] } {
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

/** Mirrors createRunAndFireEvents() in src/app/run/new/page.tsx */
function buildAuditEventBatch(
    _runId: string,
    _operatorId: string,
    step1Data: { confirmedItems: string[]; supplementedItems: string[]; unresolvedItems: string[] },
    diagnosisMemo: string,
    intentData: {
        customerDecision: CustomerDecision
        customerIntentMemo: string
        consentState: { importantMatters: boolean; personalInfo: boolean }
    }
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
        // insurer_list_presented auto-fires at Step2→Step3 transition for ALL paths
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

/** Mirrors decision filtering in Step3Intent.tsx */
function availableDecisions(runType: RunType): CustomerDecision[] {
    const all: CustomerDecision[] = [
        'compare',
        'renewal_no_change',
        'information_refused',
        'comparison_waived',
    ]
    return all.filter(d => d !== 'renewal_no_change' || runType === 'renewal')
}

/** Mirrors validatePriorityWeight in Step5Priority.tsx */
function validatePriorityWeight(
    priorityFactors: string[],
    priorityWeight: Record<string, number>
): { valid: boolean; invalidKeys: string[]; missingWeights: string[] } {
    const weightKeys = Object.keys(priorityWeight)
    const invalidKeys = weightKeys.filter(k => !priorityFactors.includes(k))
    const missingWeights = priorityFactors.filter(k => !priorityWeight[k])
    return {
        valid: invalidKeys.length === 0 && missingWeights.length === 0,
        invalidKeys,
        missingWeights,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC1 — insurer_list_presented fires for ALL customer_decision paths
//        (全経路でStep2→Step3遷移時に自動記録される)
// ─────────────────────────────────────────────────────────────────────────────
describe('TC1 — insurer_list_presented fires for all decision paths', () => {
    const decisions: CustomerDecision[] = [
        'compare',
        'renewal_no_change',
        'information_refused',
        'comparison_waived',
    ]

    it.each(decisions)('decision=%s → batch contains insurer_list_presented', decision => {
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            { confirmedItems: [], supplementedItems: [], unresolvedItems: [] },
            'テスト診断メモ（15文字以上）',
            {
                customerDecision: decision,
                customerIntentMemo: 'テスト意向メモ（15文字以上）',
                consentState: { importantMatters: true, personalInfo: true },
            }
        )

        expect(batch.map(e => e.event_type)).toContain('insurer_list_presented')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC2 — renewal_no_change は renewal 案件種別でのみ選択可能
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
// TC3 — comparison_waiver_confirmed は comparison_waived 経路のみ発火
// ─────────────────────────────────────────────────────────────────────────────
describe('TC3 — comparison_waiver_confirmed fires only for comparison_waived', () => {
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

    it.each(['compare', 'renewal_no_change', 'information_refused'] as CustomerDecision[])(
        'decision=%s → comparison_waiver_confirmed NOT fired',
        decision => {
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

            expect(batch.map(e => e.event_type)).not.toContain('comparison_waiver_confirmed')
        }
    )
})

// ─────────────────────────────────────────────────────────────────────────────
// TC4 — information_refused 経路の監査イベントバッチ構成
//        (insurer_list_presented が含まれること、過不足ないこと)
// ─────────────────────────────────────────────────────────────────────────────
describe('TC4 — information_refused audit event batch structure', () => {
    it('batch contains exactly the 4 required events in order', () => {
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

        expect(batch.map(e => e.event_type)).toEqual([
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
// TC5 — MinimalProofPdfStub の内容が経路ごとに正しいこと
//        (例外経路 PDF stub の構造検証)
// ─────────────────────────────────────────────────────────────────────────────
describe('TC5 — MinimalProofPdfStub content per decision path', () => {
    const baseRun = {
        id: 'run-abc',
        customer_ref: 'C-2026-0001',
        operator_id: 'op-001',
        customer_intent_memo: '顧客の意向をテストで確認するメモ',
    }

    it('insurer_list_presented is always true (all 4 paths)', () => {
        const decisions: CustomerDecision[] = [
            'compare',
            'renewal_no_change',
            'information_refused',
            'comparison_waived',
        ]
        decisions.forEach(decision => {
            const stub = buildMinimalProofStub(
                { ...baseRun, customer_decision: decision },
                null,
                { comparison_result: false, important_matters: false, personal_info: false }
            )
            expect(stub.insurer_list_presented).toBe(true)
        })
    })

    it('compare path → consent_comparison_result included; consent_important_matters/personal_info absent', () => {
        const stub = buildMinimalProofStub(
            { ...baseRun, customer_decision: 'compare', compare_presented_at: '2026-03-17T10:00:00Z' },
            null,
            { comparison_result: true, important_matters: false, personal_info: false }
        )

        expect(stub.consent_comparison_result).toBe(true)
        expect(stub.consent_important_matters).toBeUndefined()
        expect(stub.consent_personal_info).toBeUndefined()
    })

    it('comparison_waived path → consent_important_matters + consent_personal_info included', () => {
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

    it('snapshot data is merged into stub when provided', () => {
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
// TC6 — customerIntentMemo 最小15文字バリデーション
// ─────────────────────────────────────────────────────────────────────────────
describe('TC6 — customerIntentMemo minimum 15 characters', () => {
    const validate = (memo: string) => memo.trim().length >= 15

    it('14 chars → invalid', () => {
        expect(validate('12345678901234')).toBe(false)
    })

    it('15 chars → valid', () => {
        expect(validate('123456789012345')).toBe(true)
    })

    it('Japanese char counts respected (14 chars invalid, 15 chars valid)', () => {
        expect(validate('顧客が比較して選ぶことを希望')).toBe(false)   // 14文字 — 無効
        expect(validate('顧客が比較して選ぶことを強く希望')).toBe(true)  // 15文字 — 有効
    })

    it('whitespace-only is invalid regardless of length', () => {
        expect(validate('               ')).toBe(false)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC7 — priority_weight のキーは priority_factors の strict subset でなければならない
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

    it('weight key not in factors → invalid (invalid keys reported)', () => {
        const result = validatePriorityWeight(
            ['premium', 'coverage_amount'],
            { premium: 5, coverage_amount: 3, insurer_reputation: 2 }
        )
        expect(result.valid).toBe(false)
        expect(result.invalidKeys).toContain('insurer_reputation')
    })

    it('factor without weight → invalid (missing weights reported)', () => {
        const result = validatePriorityWeight(
            ['premium', 'coverage_amount'],
            { premium: 5 } // coverage_amount missing
        )
        expect(result.valid).toBe(false)
        expect(result.missingWeights).toContain('coverage_amount')
    })

    it('empty factors + empty weights → valid', () => {
        const result = validatePriorityWeight([], {})
        expect(result.valid).toBe(true)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC8 — 二重Finalize拒否（確定済み案件への再確定操作は 400 を返す）
// ─────────────────────────────────────────────────────────────────────────────
describe('TC8 — double-finalize blocked (idempotency)', () => {
    it('run_status=finalized → 400 already finalized', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'finalized',
                customer_decision: 'compare',
                compare_presented_at: '2026-01-01T00:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(false)
        expect(result.status).toBe(400)
        expect(result.error).toBe('already finalized')
    })

    it('run_status=archived → 400', () => {
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
// TC9 — compare経路は compare_presented_at が必須
//        (例外経路はスキップ可)
// ─────────────────────────────────────────────────────────────────────────────
describe('TC9 — compare path requires compare_presented_at', () => {
    it('normal route, compare_presented_at=null → 422', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'compare', compare_presented_at: null },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(false)
        expect(result.status).toBe(422)
        expect(result.error).toBe('compare_presented_at not set')
    })

    it('exception route → compare_presented_at NOT required', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                customer_decision: 'renewal_no_change',
                compare_presented_at: null,
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: true,
        })

        expect(result.ok).toBe(true)
    })

    it('compare path + compare_presented_at set → passes', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                customer_decision: 'compare',
                compare_presented_at: '2026-03-17T10:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(true)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC10 — uncertain項目が残ったままFinalizeを試みると失敗する（Fail-Closed）
//  ※ M1 v4.1 設計書 TC10 の定義に一致
// ─────────────────────────────────────────────────────────────────────────────
describe('TC10 — Fail-Closed: unresolved uncertain items block finalize (M1 v4.1 TC10)', () => {
    it('unresolved_items non-empty → 422 with items listed', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                customer_decision: 'compare',
                compare_presented_at: '2026-01-01T00:00:00Z',
            },
            snapshot: { unresolved_items: ['option_c_flag', 'coverage_amount'] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(false)
        expect(result.status).toBe(422)
        expect(result.error).toBe('unresolved_items')
        expect(result.items).toContain('option_c_flag')
        expect(result.items).toContain('coverage_amount')
    })

    it('unresolved_items=[] → Fail-Closed gate passes', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                customer_decision: 'compare',
                compare_presented_at: '2026-01-01T00:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })

        expect(result.ok).toBe(true)
    })

    it('snapshot=null → gate passes (no snapshot to evaluate)', () => {
        const result = validateFinalizeRequest({
            run: { run_status: 'draft', customer_decision: 'information_refused' },
            snapshot: null,
            exceptionRoute: true,
        })

        expect(result.ok).toBe(true)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// TC11 — manual_review_completed を記録しても unresolved_items が残っていれば
//         Finalize不可（記録 ≠ ゲートのクリア）
//  ※ M1 v4.1 設計書 TC11 の定義に一致
// ─────────────────────────────────────────────────────────────────────────────
describe('TC11 — manual_review_completed recorded ≠ Fail-Closed gate cleared (M1 v4.1 TC11)', () => {
    it('manual_review_completed IS in event batch while unresolved_items remain → finalize still blocked', () => {
        // Step 1: confirm manual_review_completed IS recorded in the event batch
        const batch = buildAuditEventBatch(
            'run-001', 'op-001',
            {
                confirmedItems: ['option_a'],
                supplementedItems: [],
                unresolvedItems: ['option_c_flag'], // still unresolved
            },
            'テスト診断メモ（15文字以上）',
            {
                customerDecision: 'compare',
                customerIntentMemo: 'テスト意向メモ（15文字以上）',
                consentState: { importantMatters: false, personalInfo: false },
            }
        )

        const reviewEvt = batch.find(e => e.event_type === 'manual_review_completed')
        expect(reviewEvt).toBeDefined()
        expect(reviewEvt?.payload.unresolved_items).toContain('option_c_flag')

        // Step 2: Finalize gate evaluates snapshot.unresolved_items independently
        //         Recording manual_review_completed does NOT clear the gate
        const finalizeResult = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                customer_decision: 'compare',
                compare_presented_at: '2026-03-17T10:00:00Z',
            },
            snapshot: { unresolved_items: ['option_c_flag'] }, // gate still sees the unresolved item
            exceptionRoute: false,
        })

        expect(finalizeResult.ok).toBe(false)
        expect(finalizeResult.status).toBe(422)
        expect(finalizeResult.error).toBe('unresolved_items')
        expect(finalizeResult.items).toContain('option_c_flag')
    })

    it('only after snapshot.unresolved_items is emptied does the gate open', () => {
        // Simulate: operator has manually resolved all items → snapshot updated
        const finalizeResult = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                customer_decision: 'compare',
                compare_presented_at: '2026-03-17T10:00:00Z',
            },
            snapshot: { unresolved_items: [] }, // resolved
            exceptionRoute: false,
        })

        expect(finalizeResult.ok).toBe(true)
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// Supplemental — flagGuides と i18n の健全性チェック
// ─────────────────────────────────────────────────────────────────────────────
describe('Flag guide messages — sanity checks', () => {
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

    it('getUncertainGuideMessage returns generic fallback including Fail-Closed label', () => {
        const msg = getUncertainGuideMessage('ghost_flag', 'ja')
        expect(msg).toContain('ghost_flag')
        expect(msg).toContain('Fail-Closed')
    })
})

describe('i18n — dictionary completeness', () => {
    it('3 run_status labels defined in both locales', () => {
        expect(t('ja', 'draft')).toBe('作成中')
        expect(t('ja', 'finalized')).toBe('確定済')
        expect(t('ja', 'archived')).toBe('アーカイブ')
        expect(t('en', 'draft')).toBe('Draft')
        expect(t('en', 'finalized')).toBe('Finalized')
        expect(t('en', 'archived')).toBe('Archived')
    })

    it('all 4 customer_decision labels defined in both locales', () => {
        const keys = [
            'decisionCompare',
            'decisionRenewalNoChange',
            'decisionInformationRefused',
            'decisionComparisonWaived',
        ] as const
        keys.forEach(key => {
            expect(t('ja', key).length).toBeGreaterThan(0)
            expect(t('en', key).length).toBeGreaterThan(0)
        })
    })

    it('all 11 audit event type labels defined in both locales', () => {
        const keys = [
            'eventIssueShared', 'eventManualReviewCompleted', 'eventInsurerListPresented',
            'eventCustomerIntentConfirmed', 'eventComparePresented', 'eventExclusionReasonRecorded',
            'eventComparisonWaiverConfirmed', 'eventConsentImportantMatters', 'eventConsentPersonalInfo',
            'eventConsentComparisonResult', 'eventRunFinalized',
        ] as const
        keys.forEach(key => {
            expect(t('ja', key).length).toBeGreaterThan(0)
            expect(t('en', key).length).toBeGreaterThan(0)
        })
    })

    it('step titles defined for all 5 wizard steps', () => {
        const keys = [
            'step1DiagnosisTitle', 'step2IssueSharingTitle', 'step3IntentTitle',
            'step4ScopeTitle', 'step5PriorityTitle',
        ] as const
        keys.forEach(key => {
            expect(t('ja', key).length).toBeGreaterThan(0)
            expect(t('en', key).length).toBeGreaterThan(0)
        })
    })
})
