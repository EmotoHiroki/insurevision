// =============================================
// Phase2-b-0 (MS1): 種目マスタ — クライアント側定義
// =============================================
// DB の insurance_line テーブルと一致させる静的定義。
// b0-MS1 では auto と fire の2行のみ。後続フェーズで種目を逐次追加する。
//
// 階層: InsuranceCategoryCode (5上位分類) > InsuranceLineCode (実種目)

import type { InsuranceLineCode, InsuranceCategoryCode } from '@/lib/types'

export interface InsuranceLineDef {
    code: InsuranceLineCode
    categoryCode: InsuranceCategoryCode
    labelJa: string
    labelEn: string
    milestone: string
    supportsIndividual: boolean
    supportsCorporate: boolean
    isImplemented: boolean
    sortOrder: number
}

export const INSURANCE_LINES: readonly InsuranceLineDef[] = [
    { code: 'auto', categoryCode: 'auto',     labelJa: '自動車', labelEn: 'Auto', milestone: 'Phase2-a', supportsIndividual: true, supportsCorporate: true, isImplemented: true,  sortOrder: 1 },
    { code: 'fire', categoryCode: 'property', labelJa: '火災',   labelEn: 'Fire', milestone: 'b-1',      supportsIndividual: true, supportsCorporate: true, isImplemented: false, sortOrder: 1 },
] as const

const BY_CODE: Record<InsuranceLineCode, InsuranceLineDef> =
    Object.fromEntries(INSURANCE_LINES.map(l => [l.code, l])) as Record<InsuranceLineCode, InsuranceLineDef>

export function getLine(code: InsuranceLineCode): InsuranceLineDef {
    return BY_CODE[code]
}

export function lineLabel(code: InsuranceLineCode, locale: 'ja' | 'en' = 'ja'): string {
    const def = BY_CODE[code]
    if (!def) return code
    return locale === 'ja' ? def.labelJa : def.labelEn
}

/** 指定した上位分類配下の種目一覧。 */
export function linesByCategory(categoryCode: InsuranceCategoryCode): InsuranceLineDef[] {
    return INSURANCE_LINES.filter(l => l.categoryCode === categoryCode)
}

/** 実装済み（フロー利用可能）な種目のみ。b-1 以降で順次 true 化。 */
export function implementedLines(): InsuranceLineDef[] {
    return INSURANCE_LINES.filter(l => l.isImplemented)
}

/** 顧客種別に応じて選択可能な種目。 */
export function selectableLines(customerType: 'individual' | 'corporate'): InsuranceLineDef[] {
    return INSURANCE_LINES.filter(l =>
        customerType === 'individual' ? l.supportsIndividual : l.supportsCorporate,
    )
}
