// =============================================
// Phase2-b-1 (MS1): 火災 対象物件プロファイル — 入力骨格
// =============================================
// property_profile.attributes (jsonb) に格納する火災固有属性の定義。
// 個人/企業で属性セットを切り替える（田島 2026-07-07 正式化案 §1 個人/企業統合方針）。
// 実データの投入・保存は property.ts の外（ページ側）で行う。ここは純粋な定義・判定ロジックのみ。

import type { CustomerType } from '@/lib/types'

// ── 個人: 所有形態（持家戸建 / 分譲マンション / 賃貸） ──
export type OwnershipType = 'detached_house' | 'condominium' | 'rental'

export interface OwnershipTypeDef {
    code: OwnershipType
    labelJa: string
    labelEn: string
}

export const OWNERSHIP_TYPES: readonly OwnershipTypeDef[] = [
    { code: 'detached_house', labelJa: '持家戸建',   labelEn: 'Detached house (owned)' },
    { code: 'condominium',    labelJa: '分譲マンション', labelEn: 'Condominium (owned)' },
    { code: 'rental',         labelJa: '賃貸',        labelEn: 'Rental' },
] as const

export function ownershipTypeLabel(code: OwnershipType, locale: 'ja' | 'en' = 'ja'): string {
    const def = OWNERSHIP_TYPES.find(o => o.code === code)
    if (!def) return code
    return locale === 'ja' ? def.labelJa : def.labelEn
}

// ── 個人物件属性（fire, customer_type='individual'） ──
export interface IndividualPropertyAttributes {
    ownership_type: OwnershipType
    building_structure: string | null   // 構造（木造/耐火/準耐火 等）
    floor_area_sqm: number | null
    has_household_goods: boolean        // 家財
    earthquake_insurance: boolean       // 地震保険
    // 賃貸のみ（ownership_type === 'rental' の場合に入力）
    renter_liability: boolean | null    // 借家人賠償
    personal_liability: boolean | null  // 個人賠償
}

// ── 企業物件属性（fire, customer_type='corporate'） ──
// 企業④代表シナリオ: 複数拠点・別紙明細のとおり方式（田島 2026-07-07 正式化案 §2）
export interface CorporatePropertyAttributes {
    property_count: number              // 物件数（複数拠点）
    building_structure: string | null   // 構造（共通・簡易）
    floor_area_sqm_total: number | null // 合計面積（任意）
    schedule_reference: boolean         // 支払限度額・免責金額等は「別紙明細のとおり」
    schedule_acknowledged: boolean      // 別紙明細書の受領・了知確認
}

export type PropertyAttributes = IndividualPropertyAttributes | CorporatePropertyAttributes

export function isIndividualAttributes(
    a: PropertyAttributes,
): a is IndividualPropertyAttributes {
    return 'ownership_type' in a
}

export function emptyPropertyAttributes(customerType: CustomerType): PropertyAttributes {
    if (customerType === 'individual') {
        return {
            ownership_type: 'detached_house',
            building_structure: null,
            floor_area_sqm: null,
            has_household_goods: false,
            earthquake_insurance: false,
            renter_liability: null,
            personal_liability: null,
        }
    }
    return {
        property_count: 1,
        building_structure: null,
        floor_area_sqm_total: null,
        schedule_reference: false,
        schedule_acknowledged: false,
    }
}

// 入力完了判定（Fail-Closed の最小条件。診断ロジック自体はb1-MS2）
export function isPropertyProfileComplete(customerType: CustomerType, a: PropertyAttributes): boolean {
    if (customerType === 'individual' && isIndividualAttributes(a)) {
        if (a.ownership_type === 'rental') {
            return a.renter_liability !== null && a.personal_liability !== null
        }
        return true
    }
    if (customerType === 'corporate' && !isIndividualAttributes(a)) {
        return a.property_count > 0 && (a.property_count === 1 || a.schedule_acknowledged)
    }
    return false
}

// ── 水災等地マスタ 表示ヘルパー ──
// flood_grade: 1〜5（1=最低リスク、5=最高リスク）。損害保険料率算出機構「水災等地」基準。
export function floodRiskLabel(grade: number, locale: 'ja' | 'en' = 'ja'): string {
    if (grade < 1 || grade > 5) return locale === 'ja' ? '不明' : 'Unknown'
    return locale === 'ja' ? `${grade}等地` : `Grade ${grade}`
}
