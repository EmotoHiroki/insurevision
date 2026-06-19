'use client'

import { useEffect, useState, Suspense } from 'react'
import { useParams } from 'next/navigation'
import { format } from 'date-fns'

type ReportData = {
    run: Record<string, unknown>
    operator: Record<string, unknown> | null
    candidates: Record<string, unknown>[]
    snapshot: Record<string, unknown> | null
    auditEvents: Record<string, unknown>[]
    priorCandidate: Record<string, unknown> | null
    recommendedCandidate: Record<string, unknown> | null
    decidedCandidate: Record<string, unknown> | null
    planDiffExists: boolean
}

function CustomerSheetContent() {
    const params = useParams()
    const runId = params.id as string
    const [data, setData] = useState<ReportData | null>(null)
    const [loading, setLoading] = useState(true)
    const [error, setError] = useState('')

    useEffect(() => {
        fetch(`/api/run/${runId}/report-data`)
            .then(r => r.ok ? r.json() : Promise.reject(r.statusText))
            .then(setData)
            .catch(e => setError(String(e)))
            .finally(() => setLoading(false))
    }, [runId])

    if (loading) return <div style={s.loading}>読み込み中...</div>
    if (error || !data) return <div style={s.loading}>エラー: {error}</div>

    const { run, operator, candidates, snapshot } = data
    const activePlans = candidates.filter(c => c.status === 'active')
    const consentStatus = run.electronic_consent_status as string | null
    const consentAt = run.electronic_consent_confirmed_at as string | null

    const PRODUCT_LINE_LABELS: Record<string, string> = {
        auto: '自動車保険', fire: '火災保険', life: '生命保険',
        accident: '傷害保険', marine: '海上保険', liability: '賠償責任保険',
    }

    const allFlags = [
        ...((snapshot?.missing_flags as Array<{ flag_key: string; label: string }>) ?? []),
        ...((snapshot?.uncertain_flags as Array<{ flag_key: string; label: string }>) ?? []),
    ]
    const flagLabelMap = Object.fromEntries(allFlags.map(f => [f.flag_key, f.label]))

    return (
        <div style={s.root} className="ph-root">
            {/* Zero margins/padding in print so 2x297mm fits exactly on 2 pages */}
            <style>{`@media print { .ph-root { padding: 0 !important; } .ph-page { margin: 0 !important; } .ph-page:last-of-type { page-break-after: auto !important; } }`}</style>
            {/* Print button - hidden on print */}
            <div style={s.noPrint} className="print-hide">
                <button onClick={() => window.print()} style={s.printBtn}>印刷 / PDF出力</button>
                <button onClick={() => window.history.length > 1 ? window.history.back() : window.close()} style={s.backBtn}>戻る</button>
            </div>

            {/* ═══════════════════════════════════════════════════ */}
            {/* PAGE 1 - 現契約の診断結果／意向把握                  */}
            {/* ═══════════════════════════════════════════════════ */}
            <div style={s.page} className="ph-page">
                {/* Header: consent status */}
                <div style={{ ...s.consentBanner, background: consentStatus === 'agreed' ? '#f0fdf4' : '#fff7ed', borderColor: consentStatus === 'agreed' ? '#86efac' : '#fcd34d' }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span style={{ fontSize: 9, fontWeight: 700, color: '#374151' }}>電子的方法による提供への同意</span>
                        <span style={{ fontSize: 9, fontWeight: 700, color: consentStatus === 'agreed' ? '#15803d' : '#92400e' }}>
                            {{ agreed: '同意あり', declined: '同意なし（紙面確認）', face_confirmed: '面談時確認済み', not_recorded: '未記録' }[consentStatus ?? ''] ?? '未記録'}
                            {consentAt ? `　${format(new Date(consentAt), 'yyyy年M月d日')} 取得` : ''}
                        </span>
                    </div>
                </div>

                {/* Title */}
                <div style={s.docTitle}>
                    <div style={{ fontSize: 7, color: '#6b7280', marginBottom: 2 }}>安心見える化™</div>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: '0.05em' }}>お客様シート</div>
                    <div style={{ fontSize: 8, color: '#6b7280', marginTop: 2 }}>現契約の診断結果・意向把握</div>
                </div>

                {/* Recruiter declaration */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>募集人の立場</div>
                    <div style={s.infoGrid3}>
                        <div style={s.infoCell}>
                            <div style={s.label}>代理店名</div>
                            <div style={s.value}>{operator ? String(operator.agency_name ?? '') : String(run.agency_id ?? '')}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>募集人氏名</div>
                            <div style={s.value}>{operator ? String(operator.name ?? '') : '—'}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>登録番号</div>
                            <div style={s.value}>{operator ? String(operator.license_number ?? '') : '—'}</div>
                        </div>
                    </div>
                    <div style={{ fontSize: 7, color: '#6b7280', marginTop: 4 }}>
                        当社は専属代理店として、お客様の意向に沿った最適な保険をご案内します。
                    </div>
                </div>

                {/* Customer info */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>ご契約者情報</div>
                    <div style={s.infoGrid3}>
                        <div style={s.infoCell}>
                            <div style={s.label}>お客様名</div>
                            <div style={{ ...s.value, fontWeight: 700, fontSize: 11 }}>{String(run.customer_name ?? String(run.customer_ref ?? ''))}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>お客様区分</div>
                            <div style={s.value}>{run.customer_type === 'corporate' ? '法人' : '個人'}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>参照ID</div>
                            <div style={s.value}>{String(run.customer_ref ?? '')}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>種目</div>
                            <div style={s.value}>{PRODUCT_LINE_LABELS[run.product_line as string] ?? String(run.product_line ?? '—')}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>契約種別</div>
                            <div style={s.value}>{run.run_type === 'renewal' ? '更新契約' : '新規契約'}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>面談日</div>
                            <div style={s.value}>{String(run.created_at ? format(new Date(run.created_at as string), 'yyyy年M月d日') : '—')}</div>
                        </div>
                    </div>
                </div>

                {/* Diagnosis result */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>診断結果</div>
                    {snapshot ? (
                        <>
                            <table style={s.table}>
                                <thead>
                                    <tr style={{ background: '#1e3a5f' }}>
                                        <th style={{ ...s.th, width: '35%' }}>補償項目</th>
                                        <th style={{ ...s.th, width: '25%' }}>現在の内容</th>
                                        <th style={{ ...s.th, width: '15%' }}>判定</th>
                                        <th style={{ ...s.th, width: '25%' }}>コメント</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {(snapshot.missing_flags as Array<{ flag_key: string; label: string; guide_message: string }>).map((f, i) => (
                                        <tr key={i} style={{ background: i % 2 === 0 ? '#fef2f2' : '#fff' }}>
                                            <td style={s.td}>{f.label}</td>
                                            <td style={s.td}>—</td>
                                            <td style={{ ...s.td, color: '#dc2626', fontWeight: 700, textAlign: 'center' }}>要確認</td>
                                            <td style={{ ...s.td, fontSize: 7 }}>{f.guide_message}</td>
                                        </tr>
                                    ))}
                                    {(snapshot.uncertain_flags as Array<{ flag_key: string; label: string; guide_message: string }>).map((f, i) => (
                                        <tr key={`u${i}`} style={{ background: i % 2 === 0 ? '#fffbeb' : '#fff' }}>
                                            <td style={s.td}>{f.label}</td>
                                            <td style={s.td}>—</td>
                                            <td style={{ ...s.td, color: '#d97706', fontWeight: 700, textAlign: 'center' }}>確認中</td>
                                            <td style={{ ...s.td, fontSize: 7 }}>{f.guide_message}</td>
                                        </tr>
                                    ))}
                                    {(snapshot.missing_flags as unknown[]).length === 0 && (snapshot.uncertain_flags as unknown[]).length === 0 && (
                                        <tr>
                                            <td colSpan={4} style={{ ...s.td, textAlign: 'center', color: '#16a34a', fontWeight: 700 }}>診断フラグなし（問題なし）</td>
                                        </tr>
                                    )}
                                </tbody>
                            </table>
                            {(snapshot.unresolved_items as string[]).length > 0 && (
                                <div style={{ marginTop: 6, background: '#fef2f2', border: '1px solid #fca5a5', borderRadius: 4, padding: '4px 8px' }}>
                                    <div style={{ fontSize: 8, fontWeight: 700, color: '#991b1b', marginBottom: 2 }}>特に検討すべき項目</div>
                                    {(snapshot.unresolved_items as string[]).map((item, i) => (
                                        <div key={i} style={{ fontSize: 8, color: '#7f1d1d' }}>・{flagLabelMap[item] ?? item}</div>
                                    ))}
                                </div>
                            )}
                        </>
                    ) : (
                        <div style={{ fontSize: 8, color: '#9ca3af', padding: 8 }}>診断スナップショットがありません</div>
                    )}
                </div>

                {/* Consent checkbox */}
                <div style={s.checkSection}>
                    <div style={s.checkbox} />
                    <div style={{ fontSize: 8 }}>診断結果と検討すべき項目について説明を受け、内容を確認しました。</div>
                </div>

                {/* Intent memo */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>診断後のお客様のご意向</div>
                    <div style={{ ...s.infoGrid3, gridTemplateColumns: '1fr' }}>
                        <div style={s.infoCell}>
                            <div style={s.label}>顧客判断</div>
                            <div style={s.value}>
                                {{ compare: '比較検討を希望', renewal_no_change: '現状維持（変更なし）', information_refused: '情報提供を拒否', comparison_waived: '比較免除' }[run.customer_decision as string] ?? String(run.customer_decision ?? '未記録')}
                            </div>
                        </div>
                    </div>
                    {!!run.customer_intent_memo && (
                        <div style={{ marginTop: 4, background: '#f9fafb', border: '1px solid #e5e7eb', borderRadius: 4, padding: '4px 8px', fontSize: 8 }}>
                            {String(run.customer_intent_memo)}
                        </div>
                    )}
                    <div style={{ marginTop: 8, border: '1px solid #d1d5db', borderRadius: 4, minHeight: 32, padding: 4, fontSize: 8, color: '#9ca3af' }}>
                        特に重視する点・ご自由記入:
                    </div>
                </div>

                <div style={s.pageFooter}>
                    <span>{String(run.customer_ref ?? '')} - お客様シート 1/2</span>
                    <span>安心見える化™</span>
                </div>
            </div>

            {/* ═══════════════════════════════════════════════════ */}
            {/* PAGE 2 - 比較・ご提案／ご選択・ご確認                 */}
            {/* ═══════════════════════════════════════════════════ */}
            <div style={{ ...s.page, marginTop: 0 }} className="ph-page">
                <div style={s.docTitle}>
                    <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: '0.05em' }}>お客様シート</div>
                    <div style={{ fontSize: 8, color: '#6b7280', marginTop: 2 }}>比較・ご提案 ／ ご選択・ご確認</div>
                </div>

                {/* Comparison table - variable plan count */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>保険プラン比較表</div>
                    {activePlans.length === 0 ? (
                        <div style={{ fontSize: 8, color: '#9ca3af', padding: 8 }}>比較プランが登録されていません</div>
                    ) : (
                        <table style={s.table}>
                            <thead>
                                <tr style={{ background: '#1e3a5f' }}>
                                    <th style={{ ...s.th, width: '28%' }}>補償項目 / プラン</th>
                                    {activePlans.map((p, i) => (
                                        <th key={p.id as string} style={s.th}>
                                            {p.role === 'prior' ? '前年契約' : p.role === 'same_conditions' ? '前年同条件' : `プラン${i + 1}`}
                                            <br />
                                            <span style={{ fontSize: 7, fontWeight: 400 }}>{String(p.insurer_name ?? '')}</span>
                                        </th>
                                    ))}
                                </tr>
                            </thead>
                            <tbody>
                                <tr>
                                    <td style={{ ...s.td, fontWeight: 700 }}>商品名</td>
                                    {activePlans.map(p => <td key={p.id as string} style={s.td}>{String(p.product_name ?? '—')}</td>)}
                                </tr>
                                <tr style={{ background: '#f0fdf4' }}>
                                    <td style={{ ...s.td, fontWeight: 700 }}>年間保険料</td>
                                    {activePlans.map(p => (
                                        <td key={p.id as string} style={{ ...s.td, fontWeight: 700, textAlign: 'right' }}>
                                            {p.annual_premium ? `¥${Number(p.annual_premium).toLocaleString()}` : '—'}
                                        </td>
                                    ))}
                                </tr>
                                <tr>
                                    <td style={{ ...s.td, fontWeight: 700 }}>付帯状況</td>
                                    {activePlans.map(p => (
                                        <td key={p.id as string} style={{ ...s.td, textAlign: 'center' }}>
                                            {{ full: '○ あり', partial: '△ 一部', none: '× なし' }[p.coverage_status as string] ?? '—'}
                                        </td>
                                    ))}
                                </tr>
                                <tr style={{ background: '#f9fafb' }}>
                                    <td style={{ ...s.td, fontWeight: 700, color: '#6b7280' }}>備考・除外理由</td>
                                    {activePlans.map(p => (
                                        <td key={p.id as string} style={{ ...s.td, fontSize: 7, color: '#6b7280' }}>
                                            {p.exclusion_reason_code ? `${p.exclusion_reason_code}: ${String(p.excluded_reason ?? '')}` : '—'}
                                        </td>
                                    ))}
                                </tr>
                            </tbody>
                        </table>
                    )}
                </div>

                {/* Redundancy check */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>補償重複の確認</div>
                    {snapshot && (snapshot.redundancy_decisions as unknown[]).length > 0 ? (
                        (snapshot.redundancy_decisions as Array<{ item_key: string; decision: string; reason: string }>).map((d, i) => (
                            <div key={i} style={{ fontSize: 8, display: 'flex', gap: 8, marginBottom: 2 }}>
                                <span style={{ fontWeight: 700 }}>{d.item_key}</span>
                                <span style={{ color: d.decision === 'keep' ? '#16a34a' : '#dc2626' }}>{d.decision === 'keep' ? '継続' : '削除・見直し'}</span>
                                <span style={{ color: '#6b7280' }}>{d.reason || '—'}</span>
                            </div>
                        ))
                    ) : (
                        <div style={{ fontSize: 8, color: '#6b7280' }}>□ 該当なし　　□ 該当あり（上記比較表に記載）</div>
                    )}
                </div>

                {/* Recommended plan */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>ご案内プランのご説明</div>
                    {data.recommendedCandidate ? (
                        <div style={s.infoGrid3}>
                            <div style={s.infoCell}>
                                <div style={s.label}>ご案内プラン</div>
                                <div style={{ ...s.value, fontWeight: 700 }}>{String(data.recommendedCandidate.insurer_name ?? '')} / {String(data.recommendedCandidate.product_name ?? '—')}</div>
                            </div>
                            <div style={s.infoCell}>
                                <div style={s.label}>年間保険料</div>
                                <div style={{ ...s.value, fontWeight: 700, color: '#1d4ed8' }}>
                                    {data.recommendedCandidate.annual_premium ? `¥${Number(data.recommendedCandidate.annual_premium).toLocaleString()}` : '—'}
                                </div>
                            </div>
                            <div style={s.infoCell}>
                                <div style={s.label}>ご案内理由</div>
                                <div style={s.value}>お客様の意向・補償ニーズに合致</div>
                            </div>
                        </div>
                    ) : (
                        <div style={{ fontSize: 8, color: '#9ca3af' }}>推奨プランが設定されていません</div>
                    )}
                </div>

                {/* Customer plan selection */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>プラン選択・ご確認記録</div>
                    {data.decidedCandidate ? (
                        <div style={s.infoGrid3}>
                            <div style={s.infoCell}>
                                <div style={s.label}>お客様選択プラン</div>
                                <div style={{ ...s.value, fontWeight: 700 }}>{String(data.decidedCandidate.insurer_name ?? '')} / {String(data.decidedCandidate.product_name ?? '—')}</div>
                            </div>
                            <div style={s.infoCell}>
                                <div style={s.label}>年間保険料</div>
                                <div style={{ ...s.value, fontWeight: 700 }}>
                                    {data.decidedCandidate.annual_premium ? `¥${Number(data.decidedCandidate.annual_premium).toLocaleString()}` : '—'}
                                </div>
                            </div>
                            <div style={s.infoCell}>
                                <div style={s.label}>選択理由</div>
                                <div style={s.value}>□ 保険料　□ 補償内容　□ 信頼性　□ その他</div>
                            </div>
                        </div>
                    ) : (
                        <div style={{ fontSize: 8, color: '#9ca3af' }}>お客様決定プランが設定されていません</div>
                    )}
                </div>

                {/* Important matters delivery */}
                <div style={s.checkSection}>
                    <div style={{ ...s.checkbox, background: run.important_matters_delivered ? '#1d4ed8' : 'white' }} />
                    <div style={{ fontSize: 8 }}>
                        重要事項説明書を受領しました。
                        {run.important_matters_delivered && run.important_matters_delivered_at
                            ? `　（${format(new Date(run.important_matters_delivered_at as string), 'yyyy年M月d日')} 交付 / ${run.important_matters_delivery_method === 'electronic' ? '電子交付' : '書面交付'}）`
                            : ''}
                    </div>
                </div>

                {/* Signature */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>お客様ご署名（紙面確認時）</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                        <div>
                            <div style={s.label}>お客様署名</div>
                            <div style={s.signBox} />
                        </div>
                        <div>
                            <div style={s.label}>署名日</div>
                            <div style={s.signBox} />
                        </div>
                    </div>
                </div>

                <div style={s.pageFooter}>
                    <span>{String(run.customer_ref ?? '')} - お客様シート 2/2</span>
                    <span>安心見える化™　印刷日: {format(new Date(), 'yyyy年M月d日')}</span>
                </div>
            </div>
        </div>
    )
}

export default function CustomerSheetPage() {
    return (
        <Suspense fallback={<div style={s.loading}>読み込み中...</div>}>
            <CustomerSheetContent />
        </Suspense>
    )
}

// ── Styles ───────────────────────────────────────────────────────────────────
const s: Record<string, React.CSSProperties> = {
    root: { fontFamily: '"Hiragino Kaku Gothic ProN","Meiryo","Yu Gothic",sans-serif', background: '#e5e7eb', padding: 20 },
    loading: { display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', fontFamily: 'sans-serif', color: '#6b7280' },
    noPrint: { display: 'flex', gap: 8, marginBottom: 16, justifyContent: 'flex-end' },
    printBtn: { padding: '8px 20px', background: '#1d4ed8', color: 'white', border: 'none', borderRadius: 6, cursor: 'pointer', fontSize: 13, fontWeight: 700 },
    backBtn: { padding: '8px 16px', background: 'white', color: '#374151', border: '1px solid #d1d5db', borderRadius: 6, cursor: 'pointer', fontSize: 13 },
    page: {
        width: '210mm', height: '297mm', overflow: 'hidden', background: 'white', margin: '0 auto 20px',
        padding: '10mm 12mm', boxSizing: 'border-box', position: 'relative',
        boxShadow: '0 2px 12px rgba(0,0,0,0.12)',
        pageBreakAfter: 'always',
    },
    consentBanner: { border: '1px solid', borderRadius: 4, padding: '4px 8px', marginBottom: 8 },
    docTitle: { textAlign: 'center', marginBottom: 10, borderBottom: '2px solid #1e3a5f', paddingBottom: 6 },
    section: { marginBottom: 10 },
    sectionTitle: { fontSize: 9, fontWeight: 900, color: 'white', background: '#1e3a5f', padding: '3px 8px', marginBottom: 4, letterSpacing: '0.05em' },
    infoGrid3: { display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '4px 12px' },
    infoCell: { padding: '2px 0' },
    label: { fontSize: 7, color: '#6b7280', marginBottom: 1 },
    value: { fontSize: 9, fontWeight: 500, color: '#111827' },
    table: { width: '100%', borderCollapse: 'collapse', fontSize: 8 },
    th: { padding: '3px 5px', textAlign: 'left', color: 'white', fontWeight: 700, fontSize: 7, borderRight: '1px solid #2d4a6e' },
    td: { padding: '3px 5px', borderBottom: '1px solid #e5e7eb', borderRight: '1px solid #f3f4f6', fontSize: 8, verticalAlign: 'top' },
    checkSection: { display: 'flex', alignItems: 'center', gap: 8, border: '1px solid #d1d5db', borderRadius: 4, padding: '5px 8px', marginBottom: 8 },
    checkbox: { width: 12, height: 12, border: '1.5px solid #374151', borderRadius: 2, flexShrink: 0 },
    signBox: { border: '1px solid #d1d5db', borderRadius: 4, height: 36, marginTop: 2 },
    pageFooter: { position: 'absolute', bottom: '8mm', left: '14mm', right: '14mm', display: 'flex', justifyContent: 'space-between', fontSize: 7, color: '#9ca3af', borderTop: '1px solid #e5e7eb', paddingTop: 4 },
}
