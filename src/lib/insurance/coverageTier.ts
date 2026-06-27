// =============================================
// Phase2-b-0 (MS1): 補償ティア（3段階分類）共通ロジック
// =============================================
// 補償ルールマスタ（coverage_rule_master）の tier を扱う共通定義。
// 「あるべき補償像」を物件属性 × ルールから判定する評価器の骨格を提供する。
// 実データ（火災の補償項目・条件）は b-1 火災で投入。本モジュールは構造と
// 評価アルゴリズムのみを定義する。

import type { CoverageTier, CoverageRuleMaster } from '@/lib/types'

export interface CoverageTierDef {
    tier: CoverageTier
    labelJa: string
    labelEn: string
    /** 提示順（標準必要 → 要確認 → 任意・対象外） */
    rank: number
}

export const COVERAGE_TIERS: readonly CoverageTierDef[] = [
    { tier: 'standard_required', labelJa: '標準必要',     labelEn: 'Standard required', rank: 1 },
    { tier: 'needs_check',       labelJa: '要確認',       labelEn: 'Needs check',       rank: 2 },
    { tier: 'optional_excluded', labelJa: '任意・対象外', labelEn: 'Optional / excluded', rank: 3 },
] as const

const BY_TIER: Record<CoverageTier, CoverageTierDef> =
    Object.fromEntries(COVERAGE_TIERS.map(t => [t.tier, t])) as Record<CoverageTier, CoverageTierDef>

export function tierLabel(tier: CoverageTier, locale: 'ja' | 'en' = 'ja'): string {
    const def = BY_TIER[tier]
    if (!def) return tier
    return locale === 'ja' ? def.labelJa : def.labelEn
}

export function tierRank(tier: CoverageTier): number {
    return BY_TIER[tier]?.rank ?? 99
}

/** 評価対象の物件属性。種目ごとに項目は拡張される（JSONB 由来）。 */
export type PropertyAttributes = Record<string, unknown>

/** 1補償項目に対するティア判定結果。 */
export interface CoverageEvaluation {
    coverageCode: string
    coverageLabelJa: string
    tier: CoverageTier
    intentDependent: boolean
    note: string | null
}

/**
 * ルールの condition（属性へのマッチ条件）が物件属性に合致するか判定する。
 * condition は { 属性キー: 期待値 | 期待値[] } の浅い等価マッチ。空 {} は無条件 true。
 * b-1 でより複雑な条件（範囲・比較）が必要になれば本関数を拡張する。
 */
export function conditionMatches(
    condition: Record<string, unknown>,
    attributes: PropertyAttributes,
): boolean {
    const keys = Object.keys(condition)
    if (keys.length === 0) return true
    return keys.every(key => {
        const expected = condition[key]
        const actual = attributes[key]
        if (Array.isArray(expected)) return expected.includes(actual as never)
        return expected === actual
    })
}

/**
 * あるべき補償像の評価器。
 * 補償項目ごとに、条件にマッチする最も優先度の高い（rank 最小 = 標準必要寄り）
 * ティアを採用する。マッチするルールが無い補償項目は結果から除外する。
 */
export function evaluateIdealCoverage(
    rules: CoverageRuleMaster[],
    attributes: PropertyAttributes,
): CoverageEvaluation[] {
    const byCoverage = new Map<string, CoverageEvaluation>()

    for (const rule of rules) {
        if (!rule.is_active) continue
        if (!conditionMatches(rule.condition, attributes)) continue

        const existing = byCoverage.get(rule.coverage_code)
        if (!existing || tierRank(rule.tier) < tierRank(existing.tier)) {
            byCoverage.set(rule.coverage_code, {
                coverageCode: rule.coverage_code,
                coverageLabelJa: rule.coverage_label_ja,
                tier: rule.tier,
                intentDependent: rule.intent_dependent,
                note: rule.note,
            })
        }
    }

    return [...byCoverage.values()].sort(
        (a, b) => tierRank(a.tier) - tierRank(b.tier) || a.coverageCode.localeCompare(b.coverageCode),
    )
}
