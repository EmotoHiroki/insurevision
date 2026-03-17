'use client'

import { useState } from 'react'
import { CheckSquare, Square } from 'lucide-react'
import type { CustomerDecision } from '@/lib/types'
import type { Locale } from '@/lib/i18n'
import { t } from '@/lib/i18n'

interface ConsentState {
    importantMatters: boolean
    personalInfo: boolean
}

export interface Step3Data {
    customerDecision: CustomerDecision
    customerIntentMemo: string
    consentState: ConsentState   // used only for comparison_waived path
}

interface Step3IntentProps {
    locale: Locale
    runType: 'new_contract' | 'renewal'
    onComplete: (data: Step3Data) => void
}

const DECISION_OPTIONS: Array<{
    value: CustomerDecision
    labelKey: 'decisionCompare' | 'decisionRenewalNoChange' | 'decisionInformationRefused' | 'decisionComparisonWaived'
    descJa: string
    descEn: string
    path: 'normal' | 'exception'
}> = [
    {
        value: 'compare',
        labelKey: 'decisionCompare',
        descJa: '通常経路：Step4（比較範囲）→Step5（重視事項）→比較画面',
        descEn: 'Normal path: Step4 (Scope) → Step5 (Priority) → Comparison',
        path: 'normal',
    },
    {
        value: 'renewal_no_change',
        labelKey: 'decisionRenewalNoChange',
        descJa: '例外経路①：最小証跡PDFを生成して完了',
        descEn: 'Exception ①: Generate minimal proof PDF and complete',
        path: 'exception',
    },
    {
        value: 'information_refused',
        labelKey: 'decisionInformationRefused',
        descJa: '例外経路②：最小証跡PDFを生成して完了',
        descEn: 'Exception ②: Generate minimal proof PDF and complete',
        path: 'exception',
    },
    {
        value: 'comparison_waived',
        labelKey: 'decisionComparisonWaived',
        descJa: '例外経路③：顧客同意を記録し最小証跡PDFを生成して完了',
        descEn: 'Exception ③: Record customer consent, generate minimal proof PDF and complete',
        path: 'exception',
    },
]

export default function Step3Intent({ locale, runType, onComplete }: Step3IntentProps) {
    const [customerDecision, setCustomerDecision] = useState<CustomerDecision | ''>('')
    const [customerIntentMemo, setCustomerIntentMemo] = useState('')
    const [consent, setConsent] = useState<ConsentState>({ importantMatters: false, personalInfo: false })
    const [error, setError] = useState('')

    // renewal_no_change only makes sense for renewal run_type
    const availableOptions = DECISION_OPTIONS.filter(
        (o) => o.value !== 'renewal_no_change' || runType === 'renewal'
    )

    const handleComplete = () => {
        if (!customerDecision) {
            setError(locale === 'ja' ? '顧客判断を選択してください' : 'Please select a customer decision')
            return
        }
        if (customerIntentMemo.trim().length < 15) {
            setError(t(locale, 'minChars'))
            return
        }
        if (customerDecision === 'comparison_waived') {
            if (!consent.importantMatters || !consent.personalInfo) {
                setError(
                    locale === 'ja'
                        ? '比較説明省略には重要事項・個人情報への同意が必要です'
                        : 'Comparison waiver requires consent to important matters and personal info'
                )
                return
            }
        }
        setError('')
        onComplete({
            customerDecision: customerDecision as CustomerDecision,
            customerIntentMemo: customerIntentMemo.trim(),
            consentState: consent,
        })
    }

    return (
        <div className="space-y-6">
            <div>
                <h2 className="text-lg font-semibold text-gray-800 mb-1">
                    {t(locale, 'step3IntentTitle')}
                </h2>
                <p className="text-sm text-gray-500">
                    {locale === 'ja'
                        ? '取扱保険会社リストをご確認の上、顧客の意向を選択してください。'
                        : 'After presenting the handling insurer list, select the customer\'s decision.'}
                </p>
                {/* insurer_list_presented notice */}
                <div className="mt-2 flex items-center gap-2 text-xs text-blue-700 bg-blue-50 border border-blue-200 rounded px-3 py-2">
                    <span>✓</span>
                    <span>
                        {locale === 'ja'
                            ? '取扱保険会社リストの提示が記録されます（Step2完了後に自動記録）'
                            : 'Insurer list presentation will be recorded automatically (after Step 2 completion)'}
                    </span>
                </div>
            </div>

            {/* Decision radio cards */}
            <div className="space-y-3">
                <label className="form-label">
                    {locale === 'ja' ? '顧客判断' : 'Customer Decision'}
                    <span className="badge-required">{t(locale, 'required')}</span>
                </label>
                {availableOptions.map((option) => (
                    <label
                        key={option.value}
                        className={`radio-card cursor-pointer ${
                            customerDecision === option.value ? 'ring-2 ring-blue-500' : ''
                        } ${option.path === 'exception' ? 'border-dashed' : ''}`}
                    >
                        <input
                            type="radio"
                            name="customerDecision"
                            value={option.value}
                            checked={customerDecision === option.value}
                            onChange={() => {
                                setCustomerDecision(option.value)
                                setError('')
                            }}
                            className="sr-only"
                        />
                        <div className="flex items-start gap-3">
                            <div
                                className={`mt-0.5 w-4 h-4 rounded-full border-2 shrink-0 flex items-center justify-center ${
                                    customerDecision === option.value
                                        ? 'border-blue-500 bg-blue-500'
                                        : 'border-gray-300'
                                }`}
                            >
                                {customerDecision === option.value && (
                                    <div className="w-2 h-2 rounded-full bg-white" />
                                )}
                            </div>
                            <div>
                                <p className="text-sm font-medium text-gray-800">
                                    {t(locale, option.labelKey)}
                                    {option.path === 'exception' && (
                                        <span className="ml-2 text-xs px-1.5 py-0.5 bg-orange-100 text-orange-700 rounded">
                                            {locale === 'ja' ? '例外経路' : 'Exception'}
                                        </span>
                                    )}
                                </p>
                                <p className="text-xs text-gray-500 mt-0.5">
                                    {locale === 'ja' ? option.descJa : option.descEn}
                                </p>
                            </div>
                        </div>
                    </label>
                ))}
            </div>

            {/* Comparison waived — inline consent capture */}
            {customerDecision === 'comparison_waived' && (
                <div className="section-card border-orange-200 bg-orange-50 space-y-3">
                    <p className="text-sm font-semibold text-orange-800">
                        {locale === 'ja'
                            ? '比較説明省略の同意確認（必須）'
                            : 'Consent Required for Comparison Waiver'}
                    </p>
                    <label className="flex items-start gap-2 cursor-pointer">
                        <button
                            type="button"
                            onClick={() => setConsent((c) => ({ ...c, importantMatters: !c.importantMatters }))}
                            className="mt-0.5 shrink-0"
                        >
                            {consent.importantMatters ? (
                                <CheckSquare size={18} className="text-orange-600" />
                            ) : (
                                <Square size={18} className="text-gray-400" />
                            )}
                        </button>
                        <span className="text-sm text-orange-800">{t(locale, 'consentImportantMatters')}</span>
                    </label>
                    <label className="flex items-start gap-2 cursor-pointer">
                        <button
                            type="button"
                            onClick={() => setConsent((c) => ({ ...c, personalInfo: !c.personalInfo }))}
                            className="mt-0.5 shrink-0"
                        >
                            {consent.personalInfo ? (
                                <CheckSquare size={18} className="text-orange-600" />
                            ) : (
                                <Square size={18} className="text-gray-400" />
                            )}
                        </button>
                        <span className="text-sm text-orange-800">{t(locale, 'consentPersonalInfo')}</span>
                    </label>
                </div>
            )}

            {/* Intent memo */}
            <div>
                <label className="form-label">
                    {t(locale, 'customerIntentMemo')}
                    <span className="badge-required">{t(locale, 'required')}</span>
                </label>
                <textarea
                    value={customerIntentMemo}
                    onChange={(e) => {
                        setCustomerIntentMemo(e.target.value)
                        setError('')
                    }}
                    rows={4}
                    placeholder={
                        locale === 'ja'
                            ? '顧客の意向を具体的に記録してください（15文字以上）'
                            : "Record the customer's specific intent (min 15 chars)"
                    }
                    className="form-input"
                />
                <div className="flex justify-between mt-1">
                    {error ? <span className="form-error">{error}</span> : <span />}
                    <span
                        className={`text-xs ${customerIntentMemo.length >= 15 ? 'text-green-600' : 'text-gray-400'}`}
                    >
                        {customerIntentMemo.length} / 15+
                    </span>
                </div>
            </div>

            <button type="button" onClick={handleComplete} className="btn-primary w-full">
                {customerDecision === 'compare'
                    ? t(locale, 'next')
                    : locale === 'ja'
                    ? '記録して案件を確定へ'
                    : 'Record & Proceed to Finalize'}
            </button>
        </div>
    )
}
