/**
 * InsureVision Phase2-b-0 (MS1) — 種目横断共通基盤 純粋ロジックテスト
 * =====================================================================
 * DB・HTTP には接続しない純粋ロジックの不変条件テスト。
 * 対象:
 *   - 5分類マスタ（categories）の整合
 *   - 契約フロー種別 → 診断基点・意向確認要否（contractFlow）
 *   - 補償ティア3段階分類・あるべき補償像評価器（coverageTier）
 *   - canNext 共通ポリシー（canNext）
 * =====================================================================
 */

import { describe, it, expect } from 'vitest'

import {
    INSURANCE_CATEGORIES,
    getCategory,
    categoryLabel,
    selectableCategories,
} from '@/lib/insurance/categories'
import {
    INSURANCE_LINES,
    getLine,
    lineLabel,
    linesByCategory,
    implementedLines,
} from '@/lib/insurance/lines'
import {
    CONTRACT_FLOWS,
    diagnosisBaselineFor,
    requiresIntentConfirmation,
    contractFlowFromRunType,
} from '@/lib/insurance/contractFlow'
import {
    COVERAGE_TIERS,
    tierRank,
    tierLabel,
    conditionMatches,
    evaluateIdealCoverage,
} from '@/lib/insurance/coverageTier'
import { evaluateCanNext, type CanNextContext, type GateDef } from '@/lib/insurance/canNext'
import type { CoverageRuleMaster } from '@/lib/types'

// ─────────────────────────────────────────────────────────────────────────────
// 5上位分類マスタ（insurance_category）
// ─────────────────────────────────────────────────────────────────────────────
describe('insurance categories (5上位分類マスタ)', () => {
    it('exactly 5 categories with unique codes', () => {
        expect(INSURANCE_CATEGORIES).toHaveLength(5)
        const codes = INSURANCE_CATEGORIES.map(c => c.code)
        expect(new Set(codes).size).toBe(5)
    })

    it('codes are the 5 top-level buckets', () => {
        const codes = INSURANCE_CATEGORIES.map(c => c.code).sort()
        expect(codes).toEqual(['auto', 'liability', 'person', 'profit_expense', 'property'])
    })

    it('sort order is contiguous 1..5', () => {
        const orders = INSURANCE_CATEGORIES.map(c => c.sortOrder).sort((a, b) => a - b)
        expect(orders).toEqual([1, 2, 3, 4, 5])
    })

    it('categoryLabel resolves ja/en', () => {
        expect(categoryLabel('property', 'ja')).toBe('モノ（財物）')
        expect(categoryLabel('property', 'en')).toBe('Property')
        expect(getCategory('auto').labelJa).toBe('自動車')
        expect(categoryLabel('person', 'ja')).toBe('ヒト')
    })

    it('profit_expense is corporate-only', () => {
        const indiv = selectableCategories('individual').map(c => c.code)
        const corp = selectableCategories('corporate').map(c => c.code)
        expect(indiv).not.toContain('profit_expense')
        expect(corp).toContain('profit_expense')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// 種目マスタ（insurance_line）
// ─────────────────────────────────────────────────────────────────────────────
describe('insurance lines (種目マスタ)', () => {
    it('b0-MS1 seeds exactly 2 lines: auto and fire', () => {
        expect(INSURANCE_LINES).toHaveLength(2)
        const codes = INSURANCE_LINES.map(l => l.code).sort()
        expect(codes).toEqual(['auto', 'fire'])
    })

    it('auto is the only implemented line', () => {
        const impl = implementedLines()
        expect(impl).toHaveLength(1)
        expect(impl[0].code).toBe('auto')
    })

    it('fire belongs to property category', () => {
        expect(getLine('fire').categoryCode).toBe('property')
        expect(linesByCategory('property').map(l => l.code)).toContain('fire')
    })

    it('auto belongs to auto category', () => {
        expect(getLine('auto').categoryCode).toBe('auto')
        expect(linesByCategory('auto').map(l => l.code)).toContain('auto')
    })

    it('lineLabel resolves ja/en', () => {
        expect(lineLabel('fire', 'ja')).toBe('火災')
        expect(lineLabel('fire', 'en')).toBe('Fire')
        expect(lineLabel('auto', 'ja')).toBe('自動車')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// 契約フロー種別
// ─────────────────────────────────────────────────────────────────────────────
describe('contract flow (3分類)', () => {
    it('has exactly the 3 flow types', () => {
        expect(CONTRACT_FLOWS.map(f => f.type).sort()).toEqual(
            ['new_complete', 'new_existing', 'renewal'],
        )
    })

    it('完全新規 diagnoses against あるべき補償像 (ideal_coverage_diff)', () => {
        expect(diagnosisBaselineFor('new_complete')).toBe('ideal_coverage_diff')
    })

    it('継続更改 diagnoses against current contract (contract_diff)', () => {
        expect(diagnosisBaselineFor('renewal')).toBe('contract_diff')
    })

    it('intent confirmation required for new flows, not for renewal', () => {
        expect(requiresIntentConfirmation('new_complete')).toBe(true)
        expect(requiresIntentConfirmation('new_existing')).toBe(true)
        expect(requiresIntentConfirmation('renewal')).toBe(false)
    })

    it('maps legacy run_type to flow type (safe default)', () => {
        expect(contractFlowFromRunType('renewal')).toBe('renewal')
        expect(contractFlowFromRunType('new_contract')).toBe('new_existing')
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// 補償ティア・あるべき補償像評価器
// ─────────────────────────────────────────────────────────────────────────────
describe('coverage tier (3段階分類)', () => {
    it('tiers ranked 標準必要 < 要確認 < 任意・対象外', () => {
        expect(COVERAGE_TIERS).toHaveLength(3)
        expect(tierRank('standard_required')).toBeLessThan(tierRank('needs_check'))
        expect(tierRank('needs_check')).toBeLessThan(tierRank('optional_excluded'))
        expect(tierLabel('standard_required')).toBe('標準必要')
    })

    it('empty condition matches any attributes', () => {
        expect(conditionMatches({}, { anything: 1 })).toBe(true)
    })

    it('condition does shallow equality + array membership', () => {
        expect(conditionMatches({ structure: 'wood' }, { structure: 'wood' })).toBe(true)
        expect(conditionMatches({ structure: 'wood' }, { structure: 'rc' })).toBe(false)
        expect(conditionMatches({ floodGrade: [4, 5] }, { floodGrade: 5 })).toBe(true)
        expect(conditionMatches({ floodGrade: [4, 5] }, { floodGrade: 1 })).toBe(false)
    })

    function rule(p: Partial<CoverageRuleMaster> & Pick<CoverageRuleMaster, 'coverage_code' | 'tier'>): CoverageRuleMaster {
        return {
            id: p.coverage_code + '-' + p.tier,
            line_code: 'fire',
            coverage_label_ja: p.coverage_label_ja ?? p.coverage_code,
            condition: p.condition ?? {},
            intent_dependent: p.intent_dependent ?? false,
            note: p.note ?? null,
            sort_order: p.sort_order ?? 0,
            is_active: p.is_active ?? true,
            created_at: '', updated_at: '',
            ...p,
        }
    }

    it('evaluator picks the highest-priority matching tier per coverage', () => {
        const rules: CoverageRuleMaster[] = [
            // water damage: needs_check generally, but standard_required in flood grade 4-5
            rule({ coverage_code: 'water', tier: 'needs_check', condition: {} }),
            rule({ coverage_code: 'water', tier: 'standard_required', condition: { floodGrade: [4, 5] } }),
            rule({ coverage_code: 'earthquake', tier: 'needs_check', intent_dependent: true, condition: {} }),
            // inactive rule must be ignored
            rule({ coverage_code: 'water', tier: 'optional_excluded', is_active: false, condition: {} }),
        ]

        const highFlood = evaluateIdealCoverage(rules, { floodGrade: 5 })
        const water = highFlood.find(e => e.coverageCode === 'water')!
        expect(water.tier).toBe('standard_required')

        const lowFlood = evaluateIdealCoverage(rules, { floodGrade: 1 })
        expect(lowFlood.find(e => e.coverageCode === 'water')!.tier).toBe('needs_check')

        // earthquake stays needs_check + intent_dependent flag preserved
        const eq = highFlood.find(e => e.coverageCode === 'earthquake')!
        expect(eq.intentDependent).toBe(true)
    })

    it('coverages with no matching rule are excluded from result', () => {
        const rules: CoverageRuleMaster[] = [
            rule({ coverage_code: 'water', tier: 'standard_required', condition: { structure: 'wood' } }),
        ]
        const result = evaluateIdealCoverage(rules, { structure: 'rc' })
        expect(result).toHaveLength(0)
    })

    it('result is sorted by tier rank', () => {
        const rules: CoverageRuleMaster[] = [
            rule({ coverage_code: 'b_opt', tier: 'optional_excluded' }),
            rule({ coverage_code: 'a_std', tier: 'standard_required' }),
        ]
        const result = evaluateIdealCoverage(rules, {})
        expect(result.map(r => r.tier)).toEqual(['standard_required', 'optional_excluded'])
    })
})

// ─────────────────────────────────────────────────────────────────────────────
// canNext 共通ポリシー
// ─────────────────────────────────────────────────────────────────────────────
describe('canNext common policy', () => {
    const fullCtx: CanNextContext = {
        contractFlowType: 'new_complete',
        casePhase: 'preparing',
        insuranceCategoryCode: 'property',
        insuranceLineCode: 'fire',
        hasPropertyProfile: true,
        intentConfirmed: true,
        overlapChecked: true,
    }

    it('blocks in_meeting when category/flow missing', () => {
        const ctx: CanNextContext = { ...fullCtx, insuranceCategoryCode: null, contractFlowType: null }
        const res = evaluateCanNext(ctx, 'in_meeting')
        expect(res.canNext).toBe(false)
        expect(res.blockedReasons).toContain('category_required')
        expect(res.blockedReasons).toContain('contract_flow_required')
    })

    it('allows in_meeting once category + flow set', () => {
        const res = evaluateCanNext(fullCtx, 'in_meeting')
        expect(res.canNext).toBe(true)
        expect(res.blockedReasons).toHaveLength(0)
    })

    it('blocks completion when intent confirmation incomplete (new_complete)', () => {
        const ctx: CanNextContext = { ...fullCtx, intentConfirmed: false, overlapChecked: false }
        const res = evaluateCanNext(ctx, 'completed')
        expect(res.canNext).toBe(false)
        expect(res.blockedReasons).toContain('intent_confirmation_required')
        expect(res.blockedReasons).toContain('overlap_check_required')
    })

    it('renewal does NOT require intent confirmation to complete', () => {
        const ctx: CanNextContext = {
            ...fullCtx,
            contractFlowType: 'renewal',
            intentConfirmed: false,
            overlapChecked: false,
        }
        const res = evaluateCanNext(ctx, 'completed')
        expect(res.canNext).toBe(true)
    })

    it('still blocks completion without property profile regardless of flow', () => {
        const ctx: CanNextContext = { ...fullCtx, contractFlowType: 'renewal', hasPropertyProfile: false }
        const res = evaluateCanNext(ctx, 'completed')
        expect(res.canNext).toBe(false)
        expect(res.blockedReasons).toContain('property_profile_required')
    })

    it('supports category-specific extra gates', () => {
        const fireGate: GateDef = {
            code: 'fire_building_value_required',
            reasonJa: '建物評価額が未入力です',
            blocksPhase: 'completed',
            isBlocked: () => true,
        }
        const res = evaluateCanNext(fullCtx, 'completed', [fireGate])
        expect(res.canNext).toBe(false)
        expect(res.blockedReasons).toContain('fire_building_value_required')
    })
})
