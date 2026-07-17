// =============================================
// Phase2-b-1 (MS1): 火災 対象物件プロファイル — 入力骨格
// =============================================
// property_profile.attributes (jsonb) に格納する火災固有属性の定義。
// 個人/企業で属性セットを切り替える（田島 2026-07-07 正式化案 §1 個人/企業統合方針）。
// 実データの投入・保存は property.ts の外（ページ側）で行う。ここは純粋な定義・判定ロジックのみ。
//
// 未回答/はい/いいえの三値管理（田島 2026-07-12・2026-07-16 指摘反映）:
// 所有形態・家財・地震保険・物件数・別紙明細関連は、既定値で補完せず null=未回答として保持する。
// 「未回答」と「いいえ」を区別できないと、未確認のまま完了扱いになるリスクがあるため。

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
// null = 未回答。既定値での補完は行わない。
export interface IndividualPropertyAttributes {
    ownership_type: OwnershipType | null
    building_structure: string | null   // 構造（木造/耐火/準耐火 等）
    floor_area_sqm: number | null
    has_household_goods: boolean | null        // 家財（未回答/はい/いいえ）
    earthquake_insurance: boolean | null       // 地震保険（未回答/はい/いいえ）
    // 賃貸のみ（ownership_type === 'rental' の場合に入力）
    renter_liability: boolean | null    // 借家人賠償
    personal_liability: boolean | null  // 個人賠償
}

// ── 企業物件属性（fire, customer_type='corporate'） ──
// 企業④代表シナリオ: 複数拠点・別紙明細のとおり方式（田島 2026-07-07 正式化案 §2）
// null = 未回答。既定値での補完は行わない。
//
// schedule_reference は複数物件（property_count >= 2）の前提として自動的に true が
// 導出される派生値であり、利用者が直接選択する項目ではない（田島 2026-07-16指摘）。
// 「別紙明細を参照する＝いいえ」かつ「受領確認＝はい」という矛盾状態を防ぐため、
// deriveScheduleReference() で単一物件=false/未該当、複数物件=true に統一する。
export interface CorporatePropertyAttributes {
    property_count: number | null              // 物件数（複数拠点）。未回答=null
    building_structure: string | null   // 構造（共通・簡易）
    floor_area_sqm_total: number | null // 合計面積（任意）
    schedule_reference: boolean | null         // 支払限度額・免責金額等は「別紙明細のとおり」（複数物件時は自動導出。利用者は選択不可）
    schedule_acknowledged: boolean | null      // 別紙明細書の受領・了知確認（利用者が回答する唯一の項目）
}

// property_count に応じて schedule_reference を自動導出する。
// 複数物件（2件以上）は必ず別紙明細参照が前提となるため true 固定。
// 単一物件・未回答の場合は該当しないため null。
export function deriveScheduleReference(propertyCount: number | null): boolean | null {
    if (propertyCount === null || propertyCount < 2) return null
    return true
}

export type PropertyAttributes = IndividualPropertyAttributes | CorporatePropertyAttributes

export function isIndividualAttributes(
    a: PropertyAttributes,
): a is IndividualPropertyAttributes {
    return 'ownership_type' in a
}

// すべて未回答（null）の初期状態。既定値による補完は行わない。
export function emptyPropertyAttributes(customerType: CustomerType): PropertyAttributes {
    if (customerType === 'individual') {
        return {
            ownership_type: null,
            building_structure: null,
            floor_area_sqm: null,
            has_household_goods: null,
            earthquake_insurance: null,
            renter_liability: null,
            personal_liability: null,
        }
    }
    return {
        property_count: null,
        building_structure: null,
        floor_area_sqm_total: null,
        schedule_reference: null,
        schedule_acknowledged: null,
    }
}

// 入力完了判定（Fail-Closed の最小条件。必須項目の詳細範囲はb1-MS2で整理）
// - 空の個人/企業プロファイルは不完了
// - 完了判定の対象となるはい/いいえ項目が未回答（null）の場合は不完了
// - 企業の複数物件（property_count >= 2）は、別紙明細の受領確認（schedule_acknowledged === true）を必須とする
// - schedule_reference が false（別紙参照なしと明示された矛盾状態）の場合は、
//   schedule_acknowledgedの値に関わらず不完了とする（田島 2026-07-16指摘の矛盾防止）
export function isPropertyProfileComplete(customerType: CustomerType, a: PropertyAttributes): boolean {
    if (customerType === 'individual' && isIndividualAttributes(a)) {
        if (a.ownership_type === null) return false
        if (a.has_household_goods === null) return false
        if (a.earthquake_insurance === null) return false
        if (a.ownership_type === 'rental') {
            return a.renter_liability !== null && a.personal_liability !== null
        }
        return true
    }
    if (customerType === 'corporate' && !isIndividualAttributes(a)) {
        if (a.property_count === null || a.property_count < 1) return false
        if (a.property_count === 1) return true
        if (a.schedule_reference === false) return false
        return a.schedule_acknowledged === true
    }
    return false
}

// ── 水災等地マスタ 表示ヘルパー ──
// flood_grade: 1〜5（1=最低リスク、5=最高リスク）。損害保険料率算出機構「水災等地」基準。
export function floodRiskLabel(grade: number, locale: 'ja' | 'en' = 'ja'): string {
    if (grade < 1 || grade > 5) return locale === 'ja' ? '不明' : 'Unknown'
    return locale === 'ja' ? `${grade}等地` : `Grade ${grade}`
}
