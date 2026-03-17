'use client'

import { useState } from 'react'
import { FileText, Database, CheckCircle, Circle, Wrench } from 'lucide-react'
import RecruiterGuidance from '@/components/RecruiterGuidance'
import { getMissingGuideMessage, getUncertainGuideMessage } from '@/lib/flagGuides'
import type { SnapshotFlag } from '@/lib/types'
import type { Locale } from '@/lib/i18n'
import { t } from '@/lib/i18n'

// M1: mock flags simulating core logic output.
// Phase 2: replace with actual core logic API call.
const MOCK_MISSING_FLAGS: SnapshotFlag[] = [
    {
        flag_key: 'option_a',
        label: '比較項目A（弁護士費用特約）',
        guide_message: getMissingGuideMessage('option_a', 'ja'),
    },
    {
        flag_key: 'option_b',
        label: '比較項目B（ロードサービス）',
        guide_message: getMissingGuideMessage('option_b', 'ja'),
    },
]

const MOCK_UNCERTAIN_FLAGS: SnapshotFlag[] = [
    {
        flag_key: 'option_c_flag',
        label: '比較項目C（車両補償）',
        guide_message: getUncertainGuideMessage('option_c_flag', 'ja'),
    },
]

export interface Step1Data {
    csvImported: boolean
    pdfObjectKey: string
    missingFlags: SnapshotFlag[]
    uncertainFlags: SnapshotFlag[]
    confirmedItems: string[]
    supplementedItems: string[]
    unresolvedItems: string[]
}

interface Step1DiagnosisProps {
    locale: Locale
    onComplete: (data: Step1Data) => void
}

export default function Step1Diagnosis({ locale, onComplete }: Step1DiagnosisProps) {
    const [csvImported, setCsvImported] = useState(false)
    const [pdfObjectKey, setPdfObjectKey] = useState('')
    // Per-flag review state: 'pending' | 'confirmed' | 'supplemented'
    const [flagStatus, setFlagStatus] = useState<Record<string, 'pending' | 'confirmed' | 'supplemented'>>({})
    const [error, setError] = useState('')

    const allFlags = [
        ...MOCK_MISSING_FLAGS.map((f) => ({ ...f, type: 'missing' as const })),
        ...MOCK_UNCERTAIN_FLAGS.map((f) => ({ ...f, type: 'uncertain' as const })),
    ]

    const getStatus = (key: string) => flagStatus[key] ?? 'pending'

    const setStatus = (key: string, status: 'confirmed' | 'supplemented') => {
        setFlagStatus((prev) => ({ ...prev, [key]: status }))
        setError('')
    }

    const confirmedItems = allFlags
        .filter((f) => getStatus(f.flag_key) === 'confirmed')
        .map((f) => f.flag_key)

    const supplementedItems = allFlags
        .filter((f) => getStatus(f.flag_key) === 'supplemented')
        .map((f) => f.flag_key)

    const unresolvedItems = allFlags
        .filter((f) => getStatus(f.flag_key) === 'pending')
        .map((f) => f.flag_key)

    const handleComplete = () => {
        // uncertain flags MUST be resolved (confirmed or supplemented) — Fail-Closed
        const unresolvedUncertain = MOCK_UNCERTAIN_FLAGS.filter(
            (f) => getStatus(f.flag_key) === 'pending'
        )
        if (unresolvedUncertain.length > 0) {
            setError(
                locale === 'ja'
                    ? '不確定フラグ（Fail-Closed）はすべて確認または補完が必要です'
                    : 'All uncertain flags (Fail-Closed) must be confirmed or supplemented'
            )
            return
        }

        onComplete({
            csvImported,
            pdfObjectKey,
            missingFlags: MOCK_MISSING_FLAGS,
            uncertainFlags: MOCK_UNCERTAIN_FLAGS,
            confirmedItems,
            supplementedItems,
            unresolvedItems,
        })
    }

    return (
        <div className="space-y-6">
            <div>
                <h2 className="text-lg font-semibold text-gray-800 mb-1">
                    {t(locale, 'step1DiagnosisTitle')}
                </h2>
                <p className="text-sm text-gray-500">
                    {locale === 'ja'
                        ? '証券情報を確認し、コアロジックの診断結果をレビューしてください。'
                        : 'Review policy data and confirm the core logic diagnosis results.'}
                </p>
            </div>

            {/* CSV / PDF import section */}
            <div className="section-card space-y-4">
                <h3 className="text-sm font-semibold text-gray-700">
                    {locale === 'ja' ? 'データ取込' : 'Data Import'}
                </h3>

                {/* CSV imported toggle */}
                <label className="flex items-center gap-3 cursor-pointer">
                    <input
                        type="checkbox"
                        checked={csvImported}
                        onChange={(e) => setCsvImported(e.target.checked)}
                        className="w-4 h-4 rounded"
                    />
                    <div className="flex items-center gap-2">
                        <Database size={16} className="text-gray-500" />
                        <span className="text-sm text-gray-700">{t(locale, 'snapshotCsvImported')}</span>
                    </div>
                </label>

                {/* PDF upload (display only for M1 — Phase 2 adds OCR) */}
                <div>
                    <label className="form-label">
                        <FileText size={14} className="inline mr-1" />
                        {t(locale, 'snapshotPdfKey')}
                        <span className="ml-2 text-xs text-gray-400">
                            {locale === 'ja' ? '（Phase1: ファイル名のみ記録）' : '(Phase1: file name only)'}
                        </span>
                    </label>
                    <input
                        type="text"
                        value={pdfObjectKey}
                        onChange={(e) => setPdfObjectKey(e.target.value)}
                        placeholder={locale === 'ja' ? '例: policy_2026_yamada.pdf' : 'e.g. policy_2026_yamada.pdf'}
                        className="form-input"
                    />
                </div>
            </div>

            {/* Diagnosis results — flag review */}
            <div className="section-card space-y-4">
                <h3 className="text-sm font-semibold text-gray-700">
                    {locale === 'ja' ? '診断結果・募集人レビュー' : 'Diagnosis Results — Recruiter Review'}
                </h3>
                <p className="text-xs text-gray-500">
                    {locale === 'ja'
                        ? '各フラグを確認し、「確認済み」または「補完済み」にマークしてください。不確定フラグ（Fail-Closed）はすべて解決が必要です。'
                        : 'Review each flag and mark as "Confirmed" or "Supplemented". All Fail-Closed uncertain flags must be resolved.'}
                </p>

                {/* RecruiterGuidance shows the current unresolved state */}
                <RecruiterGuidance
                    missingFlags={MOCK_MISSING_FLAGS}
                    uncertainFlags={MOCK_UNCERTAIN_FLAGS}
                    unresolvedItems={unresolvedItems}
                    locale={locale}
                />

                {/* Per-flag action buttons */}
                {allFlags.length > 0 && (
                    <div className="space-y-2 mt-2">
                        {allFlags.map((flag) => {
                            const status = getStatus(flag.flag_key)
                            return (
                                <div
                                    key={flag.flag_key}
                                    className={`flex items-center justify-between rounded-lg border p-3 ${
                                        status === 'pending'
                                            ? flag.type === 'uncertain'
                                                ? 'border-amber-200 bg-amber-50'
                                                : 'border-red-100 bg-red-50'
                                            : 'border-green-200 bg-green-50'
                                    }`}
                                >
                                    <div className="flex items-center gap-2">
                                        {status === 'pending' ? (
                                            <Circle size={14} className="text-gray-400" />
                                        ) : (
                                            <CheckCircle size={14} className="text-green-500" />
                                        )}
                                        <span className="text-sm text-gray-700">{flag.label}</span>
                                    </div>

                                    <div className="flex gap-2">
                                        <button
                                            type="button"
                                            onClick={() => setStatus(flag.flag_key, 'confirmed')}
                                            className={`text-xs px-2 py-1 rounded border transition-colors ${
                                                status === 'confirmed'
                                                    ? 'bg-green-600 text-white border-green-600'
                                                    : 'border-green-300 text-green-700 hover:bg-green-50'
                                            }`}
                                        >
                                            {t(locale, 'markConfirmed')}
                                        </button>
                                        <button
                                            type="button"
                                            onClick={() => setStatus(flag.flag_key, 'supplemented')}
                                            className={`text-xs px-2 py-1 rounded border transition-colors ${
                                                status === 'supplemented'
                                                    ? 'bg-blue-600 text-white border-blue-600'
                                                    : 'border-blue-300 text-blue-700 hover:bg-blue-50'
                                            }`}
                                        >
                                            <Wrench size={11} className="inline mr-1" />
                                            {t(locale, 'markSupplemented')}
                                        </button>
                                    </div>
                                </div>
                            )
                        })}
                    </div>
                )}
            </div>

            {error && <p className="form-error">{error}</p>}

            <button type="button" onClick={handleComplete} className="btn-primary w-full">
                {t(locale, 'completeReview')}
            </button>
        </div>
    )
}
