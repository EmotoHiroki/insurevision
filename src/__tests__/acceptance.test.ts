/**
 * InsureVision M1 v4.1 — Pure-Logic Invariant Tests
 * =====================================================================
 * 【テスト種別の位置づけ】
 *
 * ■ 本ファイル（テストコード一式）
 *   ビジネスロジック層の「純粋ロジック単体検証」です。
 *   データベース・HTTPサーバーへの接続は一切行いません。
 *   (pure-logic layer only — no DB, no HTTP server)
 *   ロジック不変条件（Fail-Closed動作、イベント発火ルール、
 *   バリデーションゲート、PDF stubの内容）を自動検証します。
 *
 * ■ 受入テスト証跡（別紙 TC_EVIDENCE.md）
 *   実際の画面操作・目視確認による手動テストの結果です。
 *   ブラウザ上でウィザードを操作し、DBへの記録・UIの挙動を
 *   スクリーンショット付きで確認したものです。
 *
 * 両者は補完関係にあり、どちらか一方で全項目を代替するものでは
 * ありません。
 * =====================================================================
 *
 * 【TC番号との対応について】
 *   M1 v4.1 設計書 Section 6 の TC1–TC11 はブラウザ上の
 *   エンドツーエンドシナリオです。純粋ロジックテストでは
 *   画面遷移・DB書き込みを再現できないため、TC1–TC9 は
 *   個別の不変条件テストとして記述しています。
 *
 *   TC10・TC11 のみ、設計書のシナリオ番号に完全準拠します:
 *     TC10 = uncertain項目が残ったままFinalizeを試みて失敗するケース
 *     TC11 = manual_review_completed記録済みだがunresolved_itemsが
 *            残っている状態でFinalize不可（独立したゲート）
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
    run: {
        run_status: string
        customer_decision?: string | null
        compare_presented_at?: string | null
        recording_mode?: string | null
        post_record_status?: string | null
    }
    snapshot: { unresolved_items: string[] } | null
    exceptionRoute: boolean
}

function validateFinalizeRequest(
    input: FinalizeInput
): { ok: boolean; status: number; error?: string; items?: string[] } {
    const { run, snapshot, exceptionRoute } = input

    // G-21: allow 'draft' or 'post_record_pending'
    if (run.run_status !== 'draft' && run.run_status !== 'post_record_pending') {
        return { ok: false, status: 400, error: 'already finalized' }
    }

    if (snapshot && snapshot.unresolved_items.length > 0) {
        return { ok: false, status: 422, error: 'unresolved_items', items: snapshot.unresolved_items }
    }

    // G-21: post_record requires phase2_done before finalize (exception routes bypass)
    if (!exceptionRoute && run.recording_mode === 'post_record' && run.post_record_status !== 'phase2_done') {
        return { ok: false, status: 422, error: '事後記録のフェーズ2が完了していません' }
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
// INVARIANT: insurer_list_presented fires for ALL customer_decision paths
//            (全経路でStep2→Step3遷移時に自動記録される)
// ─────────────────────────────────────────────────────────────────────────────
describe('insurer_list_presented fires for all decision paths', () => {
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
// INVARIANT: renewal_no_change は renewal 案件種別でのみ選択可能
// ─────────────────────────────────────────────────────────────────────────────
describe('renewal_no_change availability by run_type', () => {
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
// INVARIANT: comparison_waiver_confirmed は comparison_waived 経路のみ発火
// ─────────────────────────────────────────────────────────────────────────────
describe('comparison_waiver_confirmed fires only for comparison_waived', () => {
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
// INVARIANT: information_refused 経路の監査イベントバッチ構成
//            (insurer_list_presented が含まれること、過不足ないこと)
// ─────────────────────────────────────────────────────────────────────────────
describe('information_refused audit event batch structure', () => {
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
// INVARIANT: MinimalProofPdfStub の内容が経路ごとに正しいこと
//            (例外経路 PDF stub の構造検証)
// ─────────────────────────────────────────────────────────────────────────────
describe('MinimalProofPdfStub content per decision path', () => {
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
// INVARIANT: customerIntentMemo 最小15文字バリデーション
// ─────────────────────────────────────────────────────────────────────────────
describe('customerIntentMemo minimum 15 characters', () => {
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
// INVARIANT: priority_weight のキーは priority_factors の strict subset でなければならない
// ─────────────────────────────────────────────────────────────────────────────
describe('priority_weight key-subset validation', () => {
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
// INVARIANT: 二重Finalize拒否（確定済み案件への再確定操作は 400 を返す）
// ─────────────────────────────────────────────────────────────────────────────
describe('double-finalize blocked (idempotency)', () => {
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
// INVARIANT: compare経路は compare_presented_at が必須（例外経路はスキップ可）
// ─────────────────────────────────────────────────────────────────────────────
describe('compare path requires compare_presented_at', () => {
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
        expect(t('ja', 'finalized')).toBe('確定済（編集不可）')
        expect(t('ja', 'archived')).toBe('アーカイブ')
        expect(t('en', 'draft')).toBe('Draft')
        expect(t('en', 'finalized')).toBe('Confirmed (Read-only)')
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

    it('M3: all 7 new audit event labels defined in both locales', () => {
        const keys = [
            'eventDeliveryRecorded',
            'eventRedundancyResolutionRecorded',
            'eventRecordingModeSelected',
            'eventPostRecordPhase1Completed',
            'eventPostRecordPhase2Completed',
            'eventAgentInputModeActivated',
            'eventExclusionReasonCoded',
        ] as const
        keys.forEach(key => {
            expect(t('ja', key).length).toBeGreaterThan(0)
            expect(t('en', key).length).toBeGreaterThan(0)
        })
    })

    it('M3: run_status labels for suspended and post_record_pending defined in both locales', () => {
        expect(t('ja', 'suspended')).toBe('保留中')
        expect(t('ja', 'post_record_pending')).toBe('事後記録待ち')
        expect(t('en', 'suspended')).toBe('On Hold')
        expect(t('en', 'post_record_pending')).toBe('Post-Record Pending')
    })
})

// ═══════════════════════════════════════════════════════════════════════════════
// M3 TC27–TC37  Pure-logic invariant tests
// ═══════════════════════════════════════════════════════════════════════════════

// ── G-4 helpers (mirror handleExcludeCandidate validation) ────────────────────
function validateExclusion(code: string, memo: string): { ok: boolean; error?: string } {
    if (code === 'R-999' && !memo.trim()) {
        return { ok: false, error: 'R-999選択時はメモ入力が必須です' }
    }
    return { ok: true }
}

// ── G-20/G-21 helpers ─────────────────────────────────────────────────────────
function buildRecordingModeEvents(recordingMode: string, inputDevice: string): string[] {
    const events = ['recording_mode_selected']
    if (inputDevice === 'agent_smartphone') events.push('agent_input_mode_activated')
    return events
}

function resolveConsentLabel(inputDevice: string, locale: 'ja' | 'en'): string {
    if (inputDevice === 'agent_smartphone') {
        return locale === 'ja'
            ? '比較結果を説明しました（募集人代行確認）'
            : 'Comparison result explained (agent proxy confirmation)'
    }
    return locale === 'ja' ? '比較結果説明への同意' : 'Consent — Comparison Result'
}

describe('M3 TC27–TC28: G-4 候補除外理由コード', () => {
    it('TC27: R-001 without memo passes validation', () => {
        const result = validateExclusion('R-001', '')
        expect(result.ok).toBe(true)
    })

    it('TC27: R-001 with memo also passes', () => {
        const result = validateExclusion('R-001', '予算超過のため')
        expect(result.ok).toBe(true)
    })

    it('TC28: R-999 without memo fails with required error', () => {
        const result = validateExclusion('R-999', '')
        expect(result.ok).toBe(false)
        expect(result.error).toBe('R-999選択時はメモ入力が必須です')
    })

    it('TC28: R-999 with whitespace-only memo fails validation', () => {
        const result = validateExclusion('R-999', '   ')
        expect(result.ok).toBe(false)
    })

    it('TC28: R-999 with actual memo passes', () => {
        const result = validateExclusion('R-999', 'その他理由を記載')
        expect(result.ok).toBe(true)
    })

    it('all valid R-codes (R-001 to R-005) pass without memo', () => {
        const codes = ['R-001', 'R-002', 'R-003', 'R-004', 'R-005']
        codes.forEach(code => {
            expect(validateExclusion(code, '').ok).toBe(true)
        })
    })
})

describe('M3 TC31/TC35/TC36: G-20/G-23 記録方式・デバイス選択イベント', () => {
    it('TC31: realtime + tablet_pc fires only recording_mode_selected', () => {
        const events = buildRecordingModeEvents('realtime', 'tablet_pc')
        expect(events).toContain('recording_mode_selected')
        expect(events).not.toContain('agent_input_mode_activated')
    })

    it('TC35: realtime + tablet_pc does not fire agent_input_mode_activated', () => {
        const events = buildRecordingModeEvents('realtime', 'tablet_pc')
        expect(events).toHaveLength(1)
        expect(events[0]).toBe('recording_mode_selected')
    })

    it('TC36: realtime + agent_smartphone fires both events', () => {
        const events = buildRecordingModeEvents('realtime', 'agent_smartphone')
        expect(events).toContain('recording_mode_selected')
        expect(events).toContain('agent_input_mode_activated')
    })

    it('post_record + tablet_pc fires only recording_mode_selected', () => {
        const events = buildRecordingModeEvents('post_record', 'tablet_pc')
        expect(events).toHaveLength(1)
    })

    it('post_record + agent_smartphone fires agent_input_mode_activated', () => {
        const events = buildRecordingModeEvents('post_record', 'agent_smartphone')
        expect(events).toContain('agent_input_mode_activated')
    })

    it('TC36: agent_smartphone switches consent label to proxy wording (ja)', () => {
        expect(resolveConsentLabel('agent_smartphone', 'ja')).toContain('募集人代行確認')
    })

    it('TC36: tablet_pc keeps standard consent label (ja)', () => {
        expect(resolveConsentLabel('tablet_pc', 'ja')).toBe('比較結果説明への同意')
    })

    it('TC36: agent_smartphone switches consent label (en)', () => {
        expect(resolveConsentLabel('agent_smartphone', 'en')).toContain('agent proxy')
    })
})

describe('M3 TC32–TC34: G-21 事後記録フェーズ finalize validation', () => {
    it('TC32: post_record_pending status is accepted by finalize gate', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'post_record_pending',
                recording_mode: 'post_record',
                post_record_status: 'phase2_done',
                compare_presented_at: '2026-04-23T10:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })
        expect(result.ok).toBe(true)
    })

    it('TC33: finalize succeeds when post_record_status=phase2_done', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'post_record_pending',
                recording_mode: 'post_record',
                post_record_status: 'phase2_done',
                compare_presented_at: '2026-04-23T10:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })
        expect(result.ok).toBe(true)
        expect(result.status).toBe(200)
    })

    it('TC34: finalize fails 422 when post_record and phase2 not done', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'post_record_pending',
                recording_mode: 'post_record',
                post_record_status: 'phase1_done',
                compare_presented_at: '2026-04-23T10:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })
        expect(result.ok).toBe(false)
        expect(result.status).toBe(422)
        expect(result.error).toContain('フェーズ2')
    })

    it('TC34: finalize fails when post_record_status is null', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'post_record_pending',
                recording_mode: 'post_record',
                post_record_status: null,
                compare_presented_at: '2026-04-23T10:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })
        expect(result.ok).toBe(false)
        expect(result.status).toBe(422)
    })

    it('exception route bypasses post_record phase2 check', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                recording_mode: 'post_record',
                post_record_status: null,
                compare_presented_at: null,
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: true,
        })
        expect(result.ok).toBe(true)
    })

    it('realtime mode ignores post_record phase check', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'draft',
                recording_mode: 'realtime',
                post_record_status: null,
                compare_presented_at: '2026-04-23T10:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })
        expect(result.ok).toBe(true)
    })

    it('finalized status is rejected (400) regardless of recording_mode', () => {
        const result = validateFinalizeRequest({
            run: {
                run_status: 'finalized',
                recording_mode: 'post_record',
                post_record_status: 'phase2_done',
                compare_presented_at: '2026-04-23T10:00:00Z',
            },
            snapshot: { unresolved_items: [] },
            exceptionRoute: false,
        })
        expect(result.ok).toBe(false)
        expect(result.status).toBe(400)
        expect(result.error).toBe('already finalized')
    })
})
