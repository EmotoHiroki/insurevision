'use client'

import { useState } from 'react'
import { AlertCircle } from 'lucide-react'
import type { SnapshotFlag } from '@/lib/types'
import type { Locale } from '@/lib/i18n'
import { t } from '@/lib/i18n'

interface Step2IssueSharingProps {
    locale: Locale
    missingFlags: SnapshotFlag[]
    uncertainFlags: SnapshotFlag[]
    onComplete: (diagnosisMemo: string) => void
}

export default function Step2IssueSharing({
    locale,
    missingFlags,
    uncertainFlags,
    onComplete,
}: Step2IssueSharingProps) {
    const [diagnosisMemo, setDiagnosisMemo] = useState('')
    const [error, setError] = useState('')

    const allIssues = [
        ...missingFlags.map((f) => ({ ...f, type: 'missing' as const })),
        ...uncertainFlags.map((f) => ({ ...f, type: 'uncertain' as const })),
    ]

    const handleComplete = () => {
        if (diagnosisMemo.trim().length < 15) {
            setError(t(locale, 'minChars'))
            return
        }
        setError('')
        onComplete(diagnosisMemo.trim())
    }

    return (
        <div className="space-y-6">
            <div>
                <h2 className="text-lg font-semibold text-gray-800 mb-1">
                    {t(locale, 'step2IssueSharingTitle')}
                </h2>
                <p className="text-sm text-gray-500">
                    {locale === 'ja'
                        ? '診断で発見された課題を顧客と共有してください。共有後、以下のメモを記入してください。'
                        : 'Share the issues identified in the diagnosis with the customer, then record the memo below.'}
                </p>
            </div>

            {/* Issue list — read-only from Step 1 */}
            {allIssues.length > 0 ? (
                <div className="section-card">
                    <h3 className="text-sm font-semibold text-gray-700 mb-3">
                        {locale === 'ja' ? '不足・不確定補償一覧' : 'Missing / Uncertain Coverage List'}
                    </h3>
                    <ul className="space-y-2">
                        {allIssues.map((issue) => (
                            <li
                                key={issue.flag_key}
                                className={`flex items-start gap-2 rounded-lg border p-3 text-sm ${
                                    issue.type === 'uncertain'
                                        ? 'border-amber-200 bg-amber-50 text-amber-800'
                                        : 'border-red-200 bg-red-50 text-red-800'
                                }`}
                            >
                                <AlertCircle
                                    size={15}
                                    className={`mt-0.5 shrink-0 ${
                                        issue.type === 'uncertain' ? 'text-amber-500' : 'text-red-500'
                                    }`}
                                />
                                <div>
                                    <span className="font-medium">{issue.label}</span>
                                    {issue.type === 'uncertain' && (
                                        <span className="ml-2 text-xs font-bold">
                                            {locale === 'ja' ? '不確定' : 'Uncertain'}
                                        </span>
                                    )}
                                    <p className="text-xs mt-0.5 opacity-80">{issue.guide_message}</p>
                                </div>
                            </li>
                        ))}
                    </ul>
                </div>
            ) : (
                <div className="section-card text-sm text-green-700 bg-green-50 border border-green-200">
                    {locale === 'ja' ? '診断フラグなし — 課題は検出されませんでした' : 'No diagnostic flags — no issues detected'}
                </div>
            )}

            {/* Diagnosis memo */}
            <div>
                <label className="form-label">
                    {t(locale, 'diagnosisMemo')}
                    <span className="badge-required">{t(locale, 'required')}</span>
                </label>
                <textarea
                    value={diagnosisMemo}
                    onChange={(e) => {
                        setDiagnosisMemo(e.target.value)
                        setError('')
                    }}
                    rows={4}
                    placeholder={
                        locale === 'ja'
                            ? '課題共有の内容・顧客の反応・補完した情報などをメモしてください（15文字以上）'
                            : 'Note what was shared, the customer\'s response, and any supplemented information (min 15 chars)'
                    }
                    className="form-input"
                />
                <div className="flex justify-between mt-1">
                    {error ? (
                        <span className="form-error">{error}</span>
                    ) : (
                        <span />
                    )}
                    <span className={`text-xs ${diagnosisMemo.length >= 15 ? 'text-green-600' : 'text-gray-400'}`}>
                        {diagnosisMemo.length} / 15+
                    </span>
                </div>
            </div>

            <button type="button" onClick={handleComplete} className="btn-primary w-full">
                {t(locale, 'shareIssues')}
            </button>
        </div>
    )
}
