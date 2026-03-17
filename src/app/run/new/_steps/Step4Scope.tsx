'use client'

import { useState } from 'react'
import type { ComparisonScope } from '@/lib/types'
import type { Locale } from '@/lib/i18n'
import { t } from '@/lib/i18n'

export interface Step4Data {
    comparisonScope: ComparisonScope
    comparisonScopeMemo: string
}

interface Step4ScopeProps {
    locale: Locale
    onComplete: (data: Step4Data) => void
}

const SCOPE_OPTIONS: Array<{
    value: ComparisonScope
    labelKey: 'scopeSameInsurer' | 'scopeMultiInsurer'
    descJa: string
    descEn: string
}> = [
    {
        value: 'same_insurer',
        labelKey: 'scopeSameInsurer',
        descJa: '現在の保険会社内でのプラン変更・見直しを比較します（2列：現在 vs 推奨）',
        descEn: 'Compare plan changes within the same insurer (2 columns: current vs recommended)',
    },
    {
        value: 'multi_insurer',
        labelKey: 'scopeMultiInsurer',
        descJa: '複数の保険会社のプランを比較します（候補ごとに列を追加）',
        descEn: 'Compare plans across multiple insurers (dynamic columns per candidate)',
    },
]

export default function Step4Scope({ locale, onComplete }: Step4ScopeProps) {
    const [comparisonScope, setComparisonScope] = useState<ComparisonScope | ''>('')
    const [comparisonScopeMemo, setComparisonScopeMemo] = useState('')
    const [error, setError] = useState('')

    const handleComplete = () => {
        if (!comparisonScope) {
            setError(locale === 'ja' ? '比較範囲を選択してください' : 'Please select a comparison scope')
            return
        }
        setError('')
        onComplete({
            comparisonScope: comparisonScope as ComparisonScope,
            comparisonScopeMemo: comparisonScopeMemo.trim(),
        })
    }

    return (
        <div className="space-y-6">
            <div>
                <h2 className="text-lg font-semibold text-gray-800 mb-1">
                    {t(locale, 'step4ScopeTitle')}
                </h2>
                <p className="text-sm text-gray-500">
                    {locale === 'ja'
                        ? '顧客と合意した比較範囲を選択してください。'
                        : 'Select the comparison scope agreed upon with the customer.'}
                </p>
            </div>

            {/* Scope radio cards */}
            <div className="space-y-3">
                <label className="form-label">
                    {t(locale, 'comparisonScope')}
                    <span className="badge-required">{t(locale, 'required')}</span>
                </label>
                {SCOPE_OPTIONS.map((option) => (
                    <label
                        key={option.value}
                        className={`radio-card cursor-pointer ${
                            comparisonScope === option.value ? 'ring-2 ring-blue-500' : ''
                        }`}
                    >
                        <input
                            type="radio"
                            name="comparisonScope"
                            value={option.value}
                            checked={comparisonScope === option.value}
                            onChange={() => {
                                setComparisonScope(option.value)
                                setError('')
                            }}
                            className="sr-only"
                        />
                        <div className="flex items-start gap-3">
                            <div
                                className={`mt-0.5 w-4 h-4 rounded-full border-2 shrink-0 flex items-center justify-center ${
                                    comparisonScope === option.value
                                        ? 'border-blue-500 bg-blue-500'
                                        : 'border-gray-300'
                                }`}
                            >
                                {comparisonScope === option.value && (
                                    <div className="w-2 h-2 rounded-full bg-white" />
                                )}
                            </div>
                            <div>
                                <p className="text-sm font-medium text-gray-800">
                                    {t(locale, option.labelKey)}
                                </p>
                                <p className="text-xs text-gray-500 mt-0.5">
                                    {locale === 'ja' ? option.descJa : option.descEn}
                                </p>
                            </div>
                        </div>
                    </label>
                ))}
            </div>

            {/* Scope memo */}
            <div>
                <label className="form-label">
                    {t(locale, 'comparisonScopeMemo')}
                    <span className="ml-2 text-xs text-gray-400">
                        {locale === 'ja' ? '（任意）' : '(optional)'}
                    </span>
                </label>
                <textarea
                    value={comparisonScopeMemo}
                    onChange={(e) => setComparisonScopeMemo(e.target.value)}
                    rows={3}
                    placeholder={
                        locale === 'ja'
                            ? '比較範囲の選択理由・顧客との合意内容などをメモしてください'
                            : 'Note the reason for this scope selection and the agreement with the customer'
                    }
                    className="form-input"
                />
            </div>

            {error && <p className="form-error">{error}</p>}

            <button type="button" onClick={handleComplete} className="btn-primary w-full">
                {t(locale, 'next')}
            </button>
        </div>
    )
}
