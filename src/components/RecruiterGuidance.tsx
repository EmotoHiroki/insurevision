'use client'

import { useState } from 'react'
import { XCircle, TriangleAlert, ChevronDown, ChevronUp, ShieldAlert } from 'lucide-react'
import type { SnapshotFlag } from '@/lib/types'
import type { Locale } from '@/lib/i18n'

interface RecruiterGuidanceProps {
    missingFlags: SnapshotFlag[]
    uncertainFlags: SnapshotFlag[]
    unresolvedItems: string[]
    locale: Locale
}

interface FlagRowProps {
    flag: SnapshotFlag
    type: 'missing' | 'uncertain'
}

function FlagRow({ flag, type }: FlagRowProps) {
    const [expanded, setExpanded] = useState(false)
    const isMissing = type === 'missing'

    return (
        <div
            className={`rounded-lg border ${
                isMissing
                    ? 'border-red-200 bg-red-50'
                    : 'border-amber-200 bg-amber-50'
            } p-3 mb-2`}
        >
            <button
                onClick={() => setExpanded((v) => !v)}
                className="w-full flex items-center justify-between text-left gap-2"
                type="button"
            >
                <div className="flex items-center gap-2">
                    {isMissing ? (
                        <XCircle className="text-red-500 shrink-0" size={16} />
                    ) : (
                        <TriangleAlert className="text-amber-500 shrink-0" size={16} />
                    )}
                    <span className={`text-sm font-medium ${isMissing ? 'text-red-800' : 'text-amber-800'}`}>
                        {flag.label}
                        {!isMissing && (
                            <span className="ml-2 text-xs font-bold text-amber-600">Fail-Closed</span>
                        )}
                    </span>
                    <span className="text-xs text-gray-400 font-mono">{flag.flag_key}</span>
                </div>
                <span className="text-gray-400 shrink-0">
                    {expanded ? <ChevronUp size={14} /> : <ChevronDown size={14} />}
                </span>
            </button>

            {expanded && (
                <div
                    className={`mt-2 pt-2 border-t text-sm ${
                        isMissing ? 'border-red-200 text-red-700' : 'border-amber-200 text-amber-700'
                    }`}
                >
                    {flag.guide_message}
                </div>
            )}
        </div>
    )
}

export default function RecruiterGuidance({
    missingFlags,
    uncertainFlags,
    unresolvedItems,
    locale,
}: RecruiterGuidanceProps) {
    const hasMissing = missingFlags.length > 0
    const hasUncertain = uncertainFlags.length > 0
    const hasUnresolved = unresolvedItems.length > 0

    if (!hasMissing && !hasUncertain && !hasUnresolved) {
        return (
            <div className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-700 flex items-center gap-2">
                <ShieldAlert className="text-green-500" size={16} />
                {locale === 'ja' ? '診断フラグなし — 全項目確認済みです' : 'No diagnostic flags — all items confirmed'}
            </div>
        )
    }

    return (
        <div className="space-y-4">
            {/* Finalize-blocking banner */}
            {hasUnresolved && (
                <div className="rounded-lg border border-red-400 bg-red-100 p-4">
                    <div className="flex items-start gap-2">
                        <ShieldAlert className="text-red-600 mt-0.5 shrink-0" size={18} />
                        <div>
                            <p className="text-sm font-bold text-red-800">
                                {locale === 'ja'
                                    ? '未解決の項目があるため確定できません（Fail-Closed）'
                                    : 'Cannot finalize — unresolved items remain (Fail-Closed)'}
                            </p>
                            <ul className="mt-1 list-disc list-inside text-xs text-red-700 space-y-0.5">
                                {unresolvedItems.map((item) => (
                                    <li key={item} className="font-mono">{item}</li>
                                ))}
                            </ul>
                        </div>
                    </div>
                </div>
            )}

            {/* Missing flags */}
            {hasMissing && (
                <div>
                    <p className="text-xs font-semibold text-red-600 uppercase tracking-wide mb-2">
                        {locale === 'ja' ? '不足フラグ（要確認）' : 'Missing Flags (Action Required)'}
                    </p>
                    {missingFlags.map((flag) => (
                        <FlagRow key={flag.flag_key} flag={flag} type="missing" />
                    ))}
                </div>
            )}

            {/* Uncertain flags */}
            {hasUncertain && (
                <div>
                    <p className="text-xs font-semibold text-amber-600 uppercase tracking-wide mb-2">
                        {locale === 'ja'
                            ? '不確定フラグ（Fail-Closed — 確認必須）'
                            : 'Uncertain Flags (Fail-Closed — Must Resolve)'}
                    </p>
                    {uncertainFlags.map((flag) => (
                        <FlagRow key={flag.flag_key} flag={flag} type="uncertain" />
                    ))}
                </div>
            )}
        </div>
    )
}
