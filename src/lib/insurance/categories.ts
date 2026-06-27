// =============================================
// Phase2-b-0 (MS1): 5上位分類マスタ — クライアント側定義
// =============================================
// DB の insurance_category テーブルと一致させる静的定義。
// マスタの正は DB だが、UI ラベル・並び順をコードからも参照できるよう同一内容をここに持つ。
// 実種目（fire 等）は src/lib/insurance/lines.ts で管理する。

import type { InsuranceCategoryCode } from '@/lib/types'

export interface InsuranceCategoryDef {
    code: InsuranceCategoryCode
    labelJa: string
    labelEn: string
    supportsIndividual: boolean
    supportsCorporate: boolean
    sortOrder: number
}

export const INSURANCE_CATEGORIES: readonly InsuranceCategoryDef[] = [
    { code: 'auto',           labelJa: '自動車',       labelEn: 'Auto',             supportsIndividual: true,  supportsCorporate: true, sortOrder: 1 },
    { code: 'property',       labelJa: 'モノ（財物）', labelEn: 'Property',         supportsIndividual: true,  supportsCorporate: true, sortOrder: 2 },
    { code: 'liability',      labelJa: '賠償責任',     labelEn: 'Liability',        supportsIndividual: true,  supportsCorporate: true, sortOrder: 3 },
    { code: 'person',         labelJa: 'ヒト',         labelEn: 'Person',           supportsIndividual: true,  supportsCorporate: true, sortOrder: 4 },
    { code: 'profit_expense', labelJa: '利益費用',     labelEn: 'Profit & Expense', supportsIndividual: false, supportsCorporate: true, sortOrder: 5 },
] as const

const BY_CODE: Record<InsuranceCategoryCode, InsuranceCategoryDef> =
    Object.fromEntries(INSURANCE_CATEGORIES.map(c => [c.code, c])) as Record<InsuranceCategoryCode, InsuranceCategoryDef>

export function getCategory(code: InsuranceCategoryCode): InsuranceCategoryDef {
    return BY_CODE[code]
}

export function categoryLabel(code: InsuranceCategoryCode, locale: 'ja' | 'en' = 'ja'): string {
    const def = BY_CODE[code]
    if (!def) return code
    return locale === 'ja' ? def.labelJa : def.labelEn
}

/** 顧客種別に応じて選択可能な上位分類。 */
export function selectableCategories(customerType: 'individual' | 'corporate'): InsuranceCategoryDef[] {
    return INSURANCE_CATEGORIES.filter(c =>
        customerType === 'individual' ? c.supportsIndividual : c.supportsCorporate,
    )
}

/** 上位分類の実装状態は insurance_line.is_implemented で管理するため、
 *  category 単位の implementedCategories は lines.ts の implementedLines() を使うこと。 */
