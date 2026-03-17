'use client'

import { useState } from 'react'
import type { Locale } from '@/lib/i18n'
import { t } from '@/lib/i18n'

export interface Step5Data {
    priorityFactors: string[]
    priorityWeight: Record<string, number>
}

interface Step5PriorityProps {
    locale: Locale
    onComplete: (data: Step5Data) => void
}

const PRIORITY_FACTOR_OPTIONS: Array<{ key: string; labelJa: string; labelEn: string }> = [
    { key: 'premium', labelJa: '保険料', labelEn: 'Premium' },
    { key: 'coverage_amount', labelJa: '補償金額', labelEn: 'Coverage Amount' },
    { key: 'rider_options', labelJa: '特約の充実度', labelEn: 'Rider Options' },
    { key: 'insurer_reputation', labelJa: '保険会社の信頼性', labelEn: 'Insurer Reputation' },
    { key: 'claim_ease', labelJa: '保険金請求のしやすさ', labelEn: 'Ease of Claims' },
    { key: 'coverage_scope', labelJa: '補償範囲の広さ', labelEn: 'Coverage Scope' },
]

const WEIGHT_OPTIONS = [1, 2, 3, 4, 5]

export default function Step5Priority({ locale, onComplete }: Step5PriorityProps) {
    const [priorityFactors, setPriorityFactors] = useState<string[]>([])
    const [priorityWeight, setPriorityWeight] = useState<Record<string, number>>({})
    const [error, setError] = useState('')

    const toggleFactor = (key: string) => {
        setPriorityFactors((prev) => {
            if (prev.includes(key)) {
                // Remove factor and its weight
                setPriorityWeight((w) => {
                    const next = { ...w }
                    delete next[key]
                    return next
                })
                return prev.filter((k) => k !== key)
            }
            return [...prev, key]
        })
        setError('')
    }

    const setWeight = (key: string, weight: number) => {
        setPriorityWeight((prev) => ({ ...prev, [key]: weight }))
        setError('')
    }

    const handleComplete = () => {
        if (priorityFactors.length === 0) {
            setError(
                locale === 'ja'
                    ? '重視事項を1つ以上選択してください'
                    : 'Please select at least one priority factor'
            )
            return
        }

        // Validate: keys in priorityWeight must be strict subset of priorityFactors
        const weightKeys = Object.keys(priorityWeight)
        const invalidKeys = weightKeys.filter((k) => !priorityFactors.includes(k))
        if (invalidKeys.length > 0) {
            setError(
                locale === 'ja'
                    ? `重みの設定に不正なキーが含まれています: ${invalidKeys.join(', ')}`
                    : `Priority weight contains invalid keys: ${invalidKeys.join(', ')}`
            )
            return
        }

        // All selected factors must have a weight assigned
        const missingWeights = priorityFactors.filter((k) => !priorityWeight[k])
        if (missingWeights.length > 0) {
            setError(
                locale === 'ja'
                    ? '選択した重視事項すべてに重みを設定してください'
                    : 'Please set a weight for every selected priority factor'
            )
            return
        }

        setError('')
        onComplete({ priorityFactors, priorityWeight })
    }

    return (
        <div className="space-y-6">
            <div>
                <h2 className="text-lg font-semibold text-gray-800 mb-1">
                    {t(locale, 'step5PriorityTitle')}
                </h2>
                <p className="text-sm text-gray-500">
                    {locale === 'ja'
                        ? '顧客が重視する項目を選択し、それぞれの重要度（1〜5）を設定してください。'
                        : 'Select the factors the customer prioritizes and set an importance score (1–5) for each.'}
                </p>
            </div>

            {/* Factor chip multi-select */}
            <div>
                <label className="form-label">
                    {t(locale, 'priorityWeight')}
                    <span className="badge-required">{t(locale, 'required')}</span>
                </label>
                <div className="flex flex-wrap gap-2 mt-2">
                    {PRIORITY_FACTOR_OPTIONS.map((option) => {
                        const selected = priorityFactors.includes(option.key)
                        return (
                            <button
                                key={option.key}
                                type="button"
                                onClick={() => toggleFactor(option.key)}
                                className={`px-3 py-1.5 rounded-full text-sm border transition-colors ${
                                    selected
                                        ? 'bg-blue-600 text-white border-blue-600'
                                        : 'bg-white text-gray-700 border-gray-300 hover:border-blue-400'
                                }`}
                            >
                                {locale === 'ja' ? option.labelJa : option.labelEn}
                            </button>
                        )
                    })}
                </div>
            </div>

            {/* Per-factor weight sliders */}
            {priorityFactors.length > 0 && (
                <div className="section-card space-y-4">
                    <p className="text-sm font-semibold text-gray-700">
                        {locale === 'ja' ? '重要度の設定（1＝低 / 5＝高）' : 'Set importance (1 = low / 5 = high)'}
                    </p>
                    {priorityFactors.map((key) => {
                        const option = PRIORITY_FACTOR_OPTIONS.find((o) => o.key === key)!
                        const currentWeight = priorityWeight[key] ?? 0
                        return (
                            <div key={key} className="flex items-center gap-4">
                                <span className="text-sm text-gray-700 w-36 shrink-0">
                                    {locale === 'ja' ? option.labelJa : option.labelEn}
                                </span>
                                <div className="flex gap-1.5">
                                    {WEIGHT_OPTIONS.map((w) => (
                                        <button
                                            key={w}
                                            type="button"
                                            onClick={() => setWeight(key, w)}
                                            className={`w-8 h-8 rounded text-xs font-semibold border transition-colors ${
                                                currentWeight === w
                                                    ? 'bg-blue-600 text-white border-blue-600'
                                                    : 'bg-white text-gray-600 border-gray-300 hover:border-blue-400'
                                            }`}
                                        >
                                            {w}
                                        </button>
                                    ))}
                                </div>
                                {currentWeight > 0 && (
                                    <span className="text-xs text-blue-600 font-medium">
                                        {currentWeight}/5
                                    </span>
                                )}
                            </div>
                        )
                    })}
                </div>
            )}

            {error && <p className="form-error">{error}</p>}

            <button type="button" onClick={handleComplete} className="btn-primary w-full">
                {locale === 'ja' ? '重視事項を確定して比較へ' : 'Confirm Priorities & Proceed to Comparison'}
            </button>
        </div>
    )
}
