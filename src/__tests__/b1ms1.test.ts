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
    type IndividualPropertyAttributes,
    type CorporatePropertyAttributes,
} from '@/lib/insurance/property'

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

describe('empty property attributes (customer_type別初期値)', () => {
    it('individual gets ownership-based shape', () => {
        const a = emptyPropertyAttributes('individual')
        expect(isIndividualAttributes(a)).toBe(true)
        if (isIndividualAttributes(a)) {
            expect(a.ownership_type).toBe('detached_house')
            expect(a.has_household_goods).toBe(false)
            expect(a.earthquake_insurance).toBe(false)
            expect(a.renter_liability).toBeNull()
        }
    })

    it('corporate gets multi-site shape', () => {
        const a = emptyPropertyAttributes('corporate')
        expect(isIndividualAttributes(a)).toBe(false)
        if (!isIndividualAttributes(a)) {
            expect(a.property_count).toBe(1)
            expect(a.schedule_reference).toBe(false)
            expect(a.schedule_acknowledged).toBe(false)
        }
    })
})

describe('property profile completeness (Fail-Closed 最小条件)', () => {
    it('individual detached house is complete without rental fields', () => {
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

    it('corporate multi-site requires schedule acknowledgment (Fail-Closed)', () => {
        const incomplete: CorporatePropertyAttributes = {
            property_count: 3,
            building_structure: null,
            floor_area_sqm_total: null,
            schedule_reference: true,
            schedule_acknowledged: false,
        }
        expect(isPropertyProfileComplete('corporate', incomplete)).toBe(false)

        const complete: CorporatePropertyAttributes = { ...incomplete, schedule_acknowledged: true }
        expect(isPropertyProfileComplete('corporate', complete)).toBe(true)
    })

    it('mismatched customer_type/attribute shape is not complete', () => {
        const individualAttrs = emptyPropertyAttributes('individual')
        expect(isPropertyProfileComplete('corporate', individualAttrs)).toBe(false)
        const corporateAttrs = emptyPropertyAttributes('corporate')
        expect(isPropertyProfileComplete('individual', corporateAttrs)).toBe(false)
    })
})
