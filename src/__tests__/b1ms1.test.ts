/**
 * Phase2-b-1 (MS1) — 対象物件プロファイル 入力骨格 純粋ロジックテスト
 * DB・HTTP には接続しない。
 */

import { describe, it, expect } from 'vitest'
import {
    OWNERSHIP_TYPES,
    ownershipTypeLabel,
    floodRiskLabel,
    emptyPropertyAttributes,
    isPropertyProfileComplete,
    isIndividualAttributes,
    deriveScheduleReference,
    normalizePropertyAttributes,
    isValidPropertyCount,
    type IndividualPropertyAttributes,
    type CorporatePropertyAttributes,
} from '@/lib/insurance/property'
import {
    canSuspend,
    canResume,
    validateSuspendInput,
    interpretUpdateResult,
    shouldShowSuccess,
} from '@/lib/insurance/suspension'

describe('ownership types (個人所有形態)', () => {
    it('exactly 3 ownership types with unique codes', () => {
        expect(OWNERSHIP_TYPES).toHaveLength(3)
        const codes = OWNERSHIP_TYPES.map(o => o.code)
        expect(new Set(codes).size).toBe(3)
        expect(codes.sort()).toEqual(['condominium', 'detached_house', 'rental'])
    })

    it('labels resolve in both locales', () => {
        expect(ownershipTypeLabel('detached_house', 'ja')).toBe('持家戸建')
        expect(ownershipTypeLabel('condominium', 'ja')).toBe('分譲マンション')
        expect(ownershipTypeLabel('rental', 'ja')).toBe('賃貸')
        expect(ownershipTypeLabel('detached_house', 'en')).toBe('Detached house (owned)')
    })

    it('unknown code falls back to the code itself', () => {
        // @ts-expect-error intentional invalid code for fallback test
        expect(ownershipTypeLabel('unknown')).toBe('unknown')
    })
})

describe('flood risk label (水災等地表示)', () => {
    it('formats grades 1-5', () => {
        expect(floodRiskLabel(1, 'ja')).toBe('1等地')
        expect(floodRiskLabel(5, 'ja')).toBe('5等地')
        expect(floodRiskLabel(3, 'en')).toBe('Grade 3')
    })

    it('out-of-range grade returns unknown', () => {
        expect(floodRiskLabel(0, 'ja')).toBe('不明')
        expect(floodRiskLabel(6, 'ja')).toBe('不明')
        expect(floodRiskLabel(0, 'en')).toBe('Unknown')
    })
})

describe('empty property attributes (未回答=null で初期化・既定値補完なし)', () => {
    it('individual starts fully unanswered', () => {
        const a = emptyPropertyAttributes('individual')
        expect(isIndividualAttributes(a)).toBe(true)
        if (isIndividualAttributes(a)) {
            expect(a.ownership_type).toBeNull()
            expect(a.has_household_goods).toBeNull()
            expect(a.earthquake_insurance).toBeNull()
            expect(a.renter_liability).toBeNull()
            expect(a.personal_liability).toBeNull()
        }
    })

    it('corporate starts fully unanswered', () => {
        const a = emptyPropertyAttributes('corporate')
        expect(isIndividualAttributes(a)).toBe(false)
        if (!isIndividualAttributes(a)) {
            expect(a.property_count).toBeNull()
            expect(a.schedule_reference).toBeNull()
            expect(a.schedule_acknowledged).toBeNull()
        }
    })
})

describe('property profile completeness (Fail-Closed 最小条件・田島 2026-07-16指摘反映)', () => {
    it('empty individual profile is incomplete', () => {
        const a = emptyPropertyAttributes('individual')
        expect(isPropertyProfileComplete('individual', a)).toBe(false)
    })

    it('empty corporate profile is incomplete', () => {
        const a = emptyPropertyAttributes('corporate')
        expect(isPropertyProfileComplete('corporate', a)).toBe(false)
    })

    it('individual is incomplete while a yes/no field in scope is unanswered (null)', () => {
        const ownershipOnly: IndividualPropertyAttributes = {
            ownership_type: 'detached_house',
            building_structure: null,
            floor_area_sqm: null,
            has_household_goods: null,   // 未回答
            earthquake_insurance: null,  // 未回答
            renter_liability: null,
            personal_liability: null,
        }
        expect(isPropertyProfileComplete('individual', ownershipOnly)).toBe(false)

        const householdAnsweredOnly: IndividualPropertyAttributes = {
            ...ownershipOnly,
            has_household_goods: false,
            earthquake_insurance: null,  // まだ未回答
        }
        expect(isPropertyProfileComplete('individual', householdAnsweredOnly)).toBe(false)
    })

    it('individual detached house is complete once ownership + yes/no fields are answered', () => {
        const a: IndividualPropertyAttributes = {
            ownership_type: 'detached_house',
            building_structure: '木造',
            floor_area_sqm: 100,
            has_household_goods: true,
            earthquake_insurance: false,
            renter_liability: null,
            personal_liability: null,
        }
        expect(isPropertyProfileComplete('individual', a)).toBe(true)
    })

    it('individual rental is incomplete until renter/personal liability answered', () => {
        const incomplete: IndividualPropertyAttributes = {
            ownership_type: 'rental',
            building_structure: null,
            floor_area_sqm: null,
            has_household_goods: true,
            earthquake_insurance: false,
            renter_liability: null,
            personal_liability: null,
        }
        expect(isPropertyProfileComplete('individual', incomplete)).toBe(false)

        const complete: IndividualPropertyAttributes = {
            ...incomplete,
            renter_liability: true,
            personal_liability: false,
        }
        expect(isPropertyProfileComplete('individual', complete)).toBe(true)
    })

    it('corporate is incomplete while property_count is unanswered (null)', () => {
        const a: CorporatePropertyAttributes = {
            property_count: null,
            building_structure: '耐火',
            floor_area_sqm_total: 500,
            schedule_reference: null,
            schedule_acknowledged: null,
        }
        expect(isPropertyProfileComplete('corporate', a)).toBe(false)
    })

    it('corporate single property is complete without schedule ack', () => {
        const a: CorporatePropertyAttributes = {
            property_count: 1,
            building_structure: '耐火',
            floor_area_sqm_total: 500,
            schedule_reference: false,
            schedule_acknowledged: false,
        }
        expect(isPropertyProfileComplete('corporate', a)).toBe(true)
    })

    it('corporate multi-site requires schedule acknowledgment === true (Fail-Closed)', () => {
        const incomplete: CorporatePropertyAttributes = {
            property_count: 3,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,
            schedule_acknowledged: false,
        }
        expect(isPropertyProfileComplete('corporate', incomplete)).toBe(false)

        const stillUnanswered: CorporatePropertyAttributes = { ...incomplete, schedule_acknowledged: null }
        expect(isPropertyProfileComplete('corporate', stillUnanswered)).toBe(false)

        const complete: CorporatePropertyAttributes = { ...incomplete, schedule_acknowledged: true }
        expect(isPropertyProfileComplete('corporate', complete)).toBe(true)
    })

    it('corporate multi-site with schedule_reference=false is incomplete even if acknowledged (contradiction guard, 田島 2026-07-16)', () => {
        const contradictory: CorporatePropertyAttributes = {
            property_count: 2,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: false,
            schedule_acknowledged: true,
        }
        expect(isPropertyProfileComplete('corporate', contradictory)).toBe(false)
    })

    it('corporate multi-site with schedule_reference=null is incomplete even if acknowledged (田島 2026-07-18 否定系)', () => {
        const unnormalized: CorporatePropertyAttributes = {
            property_count: 2,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: null,
            schedule_acknowledged: true,
        }
        expect(isPropertyProfileComplete('corporate', unnormalized)).toBe(false)

        // 正規化を通せば schedule_reference が true に再導出され、完了となる
        const normalized = normalizePropertyAttributes(unnormalized)
        expect(isPropertyProfileComplete('corporate', normalized)).toBe(true)
    })

    it('deriveScheduleReference: multi-property implies true, single/unanswered stays not-applicable (null)', () => {
        expect(deriveScheduleReference(2)).toBe(true)
        expect(deriveScheduleReference(5)).toBe(true)
        expect(deriveScheduleReference(1)).toBeNull()
        expect(deriveScheduleReference(null)).toBeNull()
    })

    it('mismatched customer_type/attribute shape is not complete', () => {
        const individualAttrs = emptyPropertyAttributes('individual')
        expect(isPropertyProfileComplete('corporate', individualAttrs)).toBe(false)
        const corporateAttrs = emptyPropertyAttributes('corporate')
        expect(isPropertyProfileComplete('individual', corporateAttrs)).toBe(false)
    })
})

describe('normalizePropertyAttributes (読込み・保存時の正規化・田島 2026-07-18指摘)', () => {
    it('re-derives schedule_reference=true for multi-property regardless of stored value', () => {
        const fromNull = normalizePropertyAttributes({
            property_count: 3,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: null,
            schedule_acknowledged: null,
        }) as CorporatePropertyAttributes
        expect(fromNull.schedule_reference).toBe(true)

        const fromFalse = normalizePropertyAttributes({
            property_count: 3,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: false,
            schedule_acknowledged: null,
        }) as CorporatePropertyAttributes
        expect(fromFalse.schedule_reference).toBe(true)
    })

    it('re-derives schedule_reference=null for single/unanswered property count', () => {
        const single = normalizePropertyAttributes({
            property_count: 1,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,   // 不整合な保存値
            schedule_acknowledged: null,
        }) as CorporatePropertyAttributes
        expect(single.schedule_reference).toBeNull()

        const unanswered = normalizePropertyAttributes({
            property_count: null,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,   // 不整合な保存値
            schedule_acknowledged: null,
        }) as CorporatePropertyAttributes
        expect(unanswered.schedule_reference).toBeNull()
    })

    it('leaves other corporate fields and individual attributes untouched', () => {
        const corp = normalizePropertyAttributes({
            property_count: 2,
            building_structure: '耐火',
            floor_area_sqm_total: 800,
            schedule_reference: null,
            schedule_acknowledged: true,
        }) as CorporatePropertyAttributes
        expect(corp.building_structure).toBe('耐火')
        expect(corp.floor_area_sqm_total).toBe(800)
        expect(corp.schedule_acknowledged).toBe(true)

        const indiv = emptyPropertyAttributes('individual')
        expect(normalizePropertyAttributes(indiv)).toEqual(indiv)
    })
})

describe('第6段階: schedule_acknowledged 非該当時 null化（田島 2026-07-21）', () => {
    it('resets schedule_acknowledged to null when reverted to single property', () => {
        const reverted = normalizePropertyAttributes({
            property_count: 1,           // 複数→単一へ戻した
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,
            schedule_acknowledged: true, // 複数物件時の残存値
        }) as CorporatePropertyAttributes
        expect(reverted.schedule_reference).toBeNull()
        expect(reverted.schedule_acknowledged).toBeNull()
    })

    it('resets schedule_acknowledged to null when property count reverted to unanswered', () => {
        const reverted = normalizePropertyAttributes({
            property_count: null,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,
            schedule_acknowledged: true,
        }) as CorporatePropertyAttributes
        expect(reverted.schedule_acknowledged).toBeNull()
    })

    it('keeps schedule_acknowledged when still multi-property', () => {
        const kept = normalizePropertyAttributes({
            property_count: 2,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,
            schedule_acknowledged: true,
        }) as CorporatePropertyAttributes
        expect(kept.schedule_reference).toBe(true)
        expect(kept.schedule_acknowledged).toBe(true)
    })
})

describe('第6段階: property_count の正整数検査（田島 2026-07-21）', () => {
    it('accepts null (unanswered) and positive integers', () => {
        expect(isValidPropertyCount(null)).toBe(true)
        expect(isValidPropertyCount(1)).toBe(true)
        expect(isValidPropertyCount(2)).toBe(true)
        expect(isValidPropertyCount(50)).toBe(true)
    })

    it('rejects 0, negatives, decimals, NaN and non-numbers', () => {
        expect(isValidPropertyCount(0)).toBe(false)
        expect(isValidPropertyCount(-1)).toBe(false)
        expect(isValidPropertyCount(2.5)).toBe(false)
        expect(isValidPropertyCount(1.0000001)).toBe(false)
        expect(isValidPropertyCount(Number.NaN)).toBe(false)
        expect(isValidPropertyCount('2')).toBe(false)
        expect(isValidPropertyCount(undefined)).toBe(false)
    })

    it('normalize coerces an invalid stored property_count to null (no silent flooring)', () => {
        const bad = normalizePropertyAttributes({
            property_count: 2.5 as unknown as number, // 不正な保存値
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,
            schedule_acknowledged: true,
        }) as CorporatePropertyAttributes
        expect(bad.property_count).toBeNull()       // 2 へ丸めない
        expect(bad.schedule_reference).toBeNull()
        expect(bad.schedule_acknowledged).toBeNull()
    })
})

// =====================================================================
// 田島様2026-08-10ご指摘②③ / 2026-08-11ご判断（案B採用）への対応
//   保留は draft からのみ。保留3項目すべて必須。
//   DB更新の error に加え「更新0件」も成功扱いしない。
// DB側の強制は migration 070・071 で二重に担保している。
// =====================================================================

describe('保留の開始可否（2026-08-11ご判断: draft からのみ）', () => {
    it('draft からは保留できる', () => {
        expect(canSuspend('draft')).toBe(true)
    })

    it('post_record_pending からは保留できない（今回の是正の中心）', () => {
        expect(canSuspend('post_record_pending')).toBe(false)
    })

    it('確定済み・アーカイブ済み・保留中からは保留できない', () => {
        expect(canSuspend('finalized')).toBe(false)
        expect(canSuspend('archived')).toBe(false)
        expect(canSuspend('suspended')).toBe(false)
    })

    it('再開できるのは保留中のみ', () => {
        expect(canResume('suspended')).toBe(true)
        expect(canResume('draft')).toBe(false)
        expect(canResume('post_record_pending')).toBe(false)
        expect(canResume('finalized')).toBe(false)
    })
})

describe('保留入力の検証（ご指摘②: 3項目すべて必須）', () => {
    it('種別とメモが揃っていれば通る', () => {
        expect(validateSuspendInput({
            runStatus: 'draft', suspensionType: 'mid_session', pendingNote: '理由',
        })).toEqual({ ok: true })
    })

    it('保留メモが空文字なら拒否する', () => {
        expect(validateSuspendInput({
            runStatus: 'draft', suspensionType: 'mid_session', pendingNote: '',
        })).toEqual({ ok: false, reason: 'note_required' })
    })

    it('保留メモが空白のみなら拒否する（trim後に空）', () => {
        expect(validateSuspendInput({
            runStatus: 'draft', suspensionType: 'mid_session', pendingNote: '   \n\t ',
        })).toEqual({ ok: false, reason: 'note_required' })
    })

    it('保留メモが null なら拒否する', () => {
        expect(validateSuspendInput({
            runStatus: 'draft', suspensionType: 'condition_adjustment', pendingNote: null,
        })).toEqual({ ok: false, reason: 'note_required' })
    })

    it('保留種別が未指定なら拒否する', () => {
        expect(validateSuspendInput({
            runStatus: 'draft', suspensionType: null, pendingNote: '理由',
        })).toEqual({ ok: false, reason: 'invalid_type' })
    })

    it('保留種別が許可値以外なら拒否する', () => {
        expect(validateSuspendInput({
            runStatus: 'draft', suspensionType: 'something_else', pendingNote: '理由',
        })).toEqual({ ok: false, reason: 'invalid_type' })
    })

    it('post_record_pending では入力が揃っていても拒否する', () => {
        expect(validateSuspendInput({
            runStatus: 'post_record_pending', suspensionType: 'mid_session', pendingNote: '理由',
        })).toEqual({ ok: false, reason: 'not_suspendable' })
    })
})

describe('DB更新結果の解釈（ご指摘③: 0件更新を成功扱いしない）', () => {
    it('errorが無く1件更新なら成功', () => {
        expect(interpretUpdateResult({ error: null, affectedRows: 1 }))
            .toEqual({ ok: true })
    })

    it('errorがあれば失敗', () => {
        expect(interpretUpdateResult({ error: new Error('rejected'), affectedRows: 1 }))
            .toEqual({ ok: false, reason: 'error' })
    })

    it('DBが拒否した場合（トリガーのRAISE）は失敗', () => {
        expect(interpretUpdateResult({
            error: { code: 'P0001', message: 'transition is not permitted' },
            affectedRows: 0,
        })).toEqual({ ok: false, reason: 'error' })
    })

    it('errorが無くても0件更新なら失敗（競合・RLS不一致・対象行なし）', () => {
        expect(interpretUpdateResult({ error: null, affectedRows: 0 }))
            .toEqual({ ok: false, reason: 'no_rows' })
    })

    it('affectedRowsがnull/undefinedでも失敗として扱う', () => {
        expect(interpretUpdateResult({ error: null, affectedRows: null }))
            .toEqual({ ok: false, reason: 'no_rows' })
        expect(interpretUpdateResult({ error: null, affectedRows: undefined }))
            .toEqual({ ok: false, reason: 'no_rows' })
    })

    it('成功トーストは成功時のみ表示する', () => {
        expect(shouldShowSuccess(interpretUpdateResult({ error: null, affectedRows: 1 }))).toBe(true)
        expect(shouldShowSuccess(interpretUpdateResult({ error: null, affectedRows: 0 }))).toBe(false)
        expect(shouldShowSuccess(interpretUpdateResult({ error: new Error('x'), affectedRows: 1 }))).toBe(false)
    })
})
