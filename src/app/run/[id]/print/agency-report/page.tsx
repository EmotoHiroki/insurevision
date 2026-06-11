'use client'

import { useEffect, useState, Suspense } from 'react'
import { useParams } from 'next/navigation'
import { format } from 'date-fns'

type QualityCheck = { label: string; pass: boolean; note: string }
type TimelineEntry = { category: string; label: string; occurred_at: string; payload_summary: string }
type AuditEvent = { id: string; event_type: string; occurred_at: string; payload: Record<string, unknown> | null }

type ReportData = {
    run: Record<string, unknown>
    operator: Record<string, unknown> | null
    candidates: Record<string, unknown>[]
    snapshot: Record<string, unknown> | null
    auditEvents: AuditEvent[]
    priorCandidate: Record<string, unknown> | null
    recommendedCandidate: Record<string, unknown> | null
    decidedCandidate: Record<string, unknown> | null
    planDiffExists: boolean
    qualityChecks: QualityCheck[]
    timeline: TimelineEntry[]
}

function AgencyReportContent() {
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

    const { run, operator, candidates, snapshot, auditEvents, priorCandidate, recommendedCandidate, decidedCandidate, planDiffExists, qualityChecks, timeline } = data
    const activePlans = candidates.filter(c => c.status === 'active')
    const printedAt = format(new Date(), 'yyyy年M月d日 HH:mm')
    const runRef = String(run.customer_ref ?? run.id ?? '')

    return (
        <div style={s.root}>
            <div style={s.noPrint} className="print-hide">
                <button onClick={() => window.print()} style={s.printBtn}>印刷 / PDF出力</button>
                <button onClick={() => window.history.back()} style={s.backBtn}>戻る</button>
            </div>

            {/* ═══════════════════════════════════════════════════ */}
            {/* PAGE 1 - 案件サマリー・3軸比較・差異・重点確認            */}
            {/* ═══════════════════════════════════════════════════ */}
            <div style={s.page}>
                <div style={s.docHeader}>
                    <div>
                        <div style={{ fontSize: 7, color: '#6b7280' }}>安心見える化™ - 社内管理用</div>
                        <div style={{ fontSize: 14, fontWeight: 900, letterSpacing: '0.05em' }}>代理店控え</div>
                        <div style={{ fontSize: 8, color: '#6b7280' }}>案件サマリー・補償比較・重点確認</div>
                    </div>
                    <div style={{ textAlign: 'right', fontSize: 8, color: '#6b7280' }}>
                        <div>印刷日: {printedAt}</div>
                        <div>Run ID: {runRef}</div>
                    </div>
                </div>

                {/* Case summary - 3 cols */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>案件サマリー</div>
                    <div style={s.grid3}>
                        <div style={s.card}>
                            <div style={s.cardLabel}>顧客情報</div>
                            <div style={s.cardValue}>{String(run.customer_name ?? runRef)}</div>
                            <div style={s.cardSub}>種目: {String(run.product_line ?? '自動車保険')}</div>
                            <div style={s.cardSub}>区分: {run.customer_type === 'corporate' ? '法人' : '個人'}</div>
                            <div style={s.cardSub}>契約種別: {run.run_type === 'renewal' ? '更新' : '新規'}</div>
                        </div>
                        <div style={s.card}>
                            <div style={s.cardLabel}>前契約（現在契約）</div>
                            {priorCandidate ? (
                                <>
                                    <div style={s.cardValue}>{String(priorCandidate.insurer_name ?? '—')}</div>
                                    <div style={s.cardSub}>{String(priorCandidate.product_name ?? '—')}</div>
                                    <div style={s.cardSub}>保険料: {priorCandidate.annual_premium ? `¥${Number(priorCandidate.annual_premium).toLocaleString()}` : '—'}</div>
                                    <div style={s.cardSub}>付帯: {{ full: '○ あり', partial: '△ 一部', none: '× なし' }[priorCandidate.coverage_status as string] ?? '—'}</div>
                                </>
                            ) : <div style={s.cardSub}>前契約なし</div>}
                        </div>
                        <div style={s.card}>
                            <div style={s.cardLabel}>今回契約（決定プラン）</div>
                            {decidedCandidate ? (
                                <>
                                    <div style={s.cardValue}>{String(decidedCandidate.insurer_name ?? '—')}</div>
                                    <div style={s.cardSub}>{String(decidedCandidate.product_name ?? '—')}</div>
                                    <div style={s.cardSub}>保険料: {decidedCandidate.annual_premium ? `¥${Number(decidedCandidate.annual_premium).toLocaleString()}` : '—'}</div>
                                    <div style={s.cardSub}>付帯: {{ full: '○ あり', partial: '△ 一部', none: '× なし' }[decidedCandidate.coverage_status as string] ?? '—'}</div>
                                </>
                            ) : <div style={{ ...s.cardSub, color: '#dc2626' }}>未決定</div>}
                        </div>
                    </div>
                </div>

                {/* 3-axis plan comparison */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>補償内容比較（3軸）</div>
                    <table style={s.table}>
                        <thead>
                            <tr style={{ background: '#1e3a5f' }}>
                                <th style={{ ...s.th, width: '28%' }}>補償軸 / 項目</th>
                                <th style={s.th}>
                                    現在契約（前年）
                                    {priorCandidate && <div style={s.axisLabel}>{String(priorCandidate.insurer_name ?? '')}</div>}
                                </th>
                                <th style={{ ...s.th, background: '#1d4ed8' }}>
                                    募集人おすすめ ★
                                    {recommendedCandidate && <div style={s.axisLabel}>{String(recommendedCandidate.insurer_name ?? '')}</div>}
                                </th>
                                <th style={{ ...s.th, background: '#166534' }}>
                                    お客様決定 ✓
                                    {decidedCandidate && <div style={s.axisLabel}>{String(decidedCandidate.insurer_name ?? '')}</div>}
                                </th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr>
                                <td style={{ ...s.td, fontWeight: 700 }}>商品名</td>
                                <td style={s.td}>{priorCandidate ? String(priorCandidate.product_name ?? '—') : '—'}</td>
                                <td style={{ ...s.td, background: '#eff6ff' }}>{recommendedCandidate ? String(recommendedCandidate.product_name ?? '—') : '未設定'}</td>
                                <td style={{ ...s.td, background: '#f0fdf4' }}>{decidedCandidate ? String(decidedCandidate.product_name ?? '—') : '未決定'}</td>
                            </tr>
                            <tr>
                                <td style={{ ...s.td, fontWeight: 700 }}>年間保険料</td>
                                <td style={s.td}>{priorCandidate?.annual_premium ? `¥${Number(priorCandidate.annual_premium).toLocaleString()}` : '—'}</td>
                                <td style={{ ...s.td, background: '#eff6ff', fontWeight: 700, color: '#1d4ed8' }}>
                                    {recommendedCandidate?.annual_premium ? `¥${Number(recommendedCandidate.annual_premium).toLocaleString()}` : '—'}
                                </td>
                                <td style={{ ...s.td, background: '#f0fdf4', fontWeight: 700, color: '#166534' }}>
                                    {decidedCandidate?.annual_premium ? `¥${Number(decidedCandidate.annual_premium).toLocaleString()}` : '—'}
                                </td>
                            </tr>
                            <tr>
                                <td style={{ ...s.td, fontWeight: 700 }}>補償付帯状況</td>
                                <td style={s.td}>{{ full: '○ あり', partial: '△ 一部', none: '× なし' }[priorCandidate?.coverage_status as string] ?? '—'}</td>
                                <td style={{ ...s.td, background: '#eff6ff' }}>{{ full: '○ あり', partial: '△ 一部', none: '× なし' }[recommendedCandidate?.coverage_status as string] ?? '—'}</td>
                                <td style={{ ...s.td, background: '#f0fdf4' }}>{{ full: '○ あり', partial: '△ 一部', none: '× なし' }[decidedCandidate?.coverage_status as string] ?? '—'}</td>
                            </tr>
                            <tr>
                                <td style={{ ...s.td, fontWeight: 700, color: '#6b7280' }}>差異フラグ</td>
                                <td style={s.td} colSpan={3}>
                                    {planDiffExists ? (
                                        <span style={{ color: '#d97706', fontWeight: 700 }}>
                                            差異あり - おすすめプランとお客様決定プランが異なります
                                        </span>
                                    ) : (
                                        <span style={{ color: '#16a34a' }}>差異なし - おすすめ＝お客様決定</span>
                                    )}
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </div>

                {/* Diff reason */}
                {planDiffExists && (
                    <div style={{ ...s.section, marginBottom: 6 }}>
                        <div style={s.sectionTitle}>差異理由（内部記録）</div>
                        {run.plan_diff_reason ? (
                            <div style={{ background: '#fffbeb', border: '1px solid #fde68a', borderRadius: 4, padding: '5px 8px', fontSize: 8 }}>
                                <span style={{ fontWeight: 700 }}>差異理由: </span>{String(run.plan_diff_reason)}
                                {!!run.plan_diff_reason_recorded_at && (
                                    <span style={{ color: '#92400e', marginLeft: 8 }}>
                                        ({format(new Date(run.plan_diff_reason_recorded_at as string), 'yyyy/M/d HH:mm')} 記録)
                                    </span>
                                )}
                            </div>
                        ) : (
                            <div style={{ background: '#fef2f2', border: '1px solid #fca5a5', borderRadius: 4, padding: '5px 8px', fontSize: 8, color: '#dc2626', fontWeight: 700 }}>
                                差異理由未記録 - 後日補完が必要です
                            </div>
                        )}
                    </div>
                )}

                {/* Key confirmation points */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>重点確認ポイント</div>
                    <div style={s.grid3}>
                        <div style={{ ...s.statusCard, borderColor: snapshot && (snapshot.redundancy_decisions as unknown[]).length > 0 ? '#f59e0b' : '#86efac' }}>
                            <div style={{ fontSize: 8, fontWeight: 700, marginBottom: 3 }}>補償重複</div>
                            {snapshot && (snapshot.redundancy_decisions as unknown[]).length > 0 ? (
                                <div style={{ fontSize: 7, color: '#92400e' }}>
                                    {(snapshot.redundancy_decisions as unknown[]).length}件の重複確認あり
                                </div>
                            ) : (
                                <div style={{ fontSize: 7, color: '#16a34a' }}>重複なし（または確認済み）</div>
                            )}
                        </div>
                        <div style={{ ...s.statusCard, borderColor: planDiffExists ? (run.plan_diff_reason ? '#f59e0b' : '#fca5a5') : '#86efac' }}>
                            <div style={{ fontSize: 8, fontWeight: 700, marginBottom: 3 }}>案内差異</div>
                            <div style={{ fontSize: 7, color: planDiffExists ? (run.plan_diff_reason ? '#92400e' : '#dc2626') : '#16a34a' }}>
                                {planDiffExists ? (run.plan_diff_reason ? '差異あり（理由記録済）' : '差異あり（理由未記録）') : '差異なし'}
                            </div>
                        </div>
                        <div style={{ ...s.statusCard, borderColor: run.smartphone_conf_status === 'customer_confirmed' ? '#86efac' : '#fca5a5' }}>
                            <div style={{ fontSize: 8, fontWeight: 700, marginBottom: 3 }}>事後記録</div>
                            <div style={{ fontSize: 7, color: run.smartphone_conf_status === 'customer_confirmed' ? '#16a34a' : '#dc2626' }}>
                                スマホ確認: {run.smartphone_conf_status === 'customer_confirmed' ? '完了' : String(run.smartphone_conf_status ?? '未確認')}
                            </div>
                        </div>
                    </div>
                </div>

                <div style={s.pageFooter}>
                    <span>{runRef} - 代理店控え 1/4</span>
                    <span>安心見える化™ [社内管理用]</span>
                </div>
            </div>

            {/* ═══════════════════════════════════════════════════ */}
            {/* PAGE 2 - 面談記録・業務品質チェック                      */}
            {/* ═══════════════════════════════════════════════════ */}
            <div style={s.page}>
                <div style={s.docHeader}>
                    <div style={{ fontSize: 13, fontWeight: 900 }}>代理店控え - 面談記録・業務品質チェック</div>
                    <div style={{ fontSize: 8, color: '#6b7280' }}>{runRef}</div>
                </div>

                {/* Interview info */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>面談・記録情報</div>
                    <div style={s.infoGrid3}>
                        <div style={s.infoCell}>
                            <div style={s.label}>担当募集人</div>
                            <div style={s.value}>{operator ? String(operator.name ?? '') : '—'}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>面談日</div>
                            <div style={s.value}>{run.created_at ? format(new Date(run.created_at as string), 'yyyy年M月d日') : '—'}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>代理店ID</div>
                            <div style={s.value}>{String(run.agency_id ?? '—')}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>電子同意</div>
                            <div style={s.value}>
                                {{ agreed: '同意あり', declined: '同意なし', face_confirmed: '面談確認済', not_recorded: '未記録' }[run.electronic_consent_status as string] ?? '—'}
                            </div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>重要事項交付</div>
                            <div style={s.value}>
                                {run.important_matters_delivered ? `交付済（${run.important_matters_delivery_method === 'electronic' ? '電子' : '書面'}）` : '未交付'}
                            </div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>スマホ確認</div>
                            <div style={s.value}>{String(run.smartphone_conf_status ?? '未使用')}</div>
                        </div>
                    </div>
                </div>

                {/* Intent / proposal / selection */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>意向・提案・選択結果</div>
                    <div style={s.infoGrid3}>
                        <div style={s.infoCell}>
                            <div style={s.label}>顧客判断</div>
                            <div style={s.value}>
                                {{ compare: '比較検討を希望', renewal_no_change: '現状維持', information_refused: '情報提供を拒否', comparison_waived: '比較免除' }[run.customer_decision as string] ?? String(run.customer_decision ?? '未記録')}
                            </div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>提案（おすすめ）プラン</div>
                            <div style={s.value}>{recommendedCandidate ? `${String(recommendedCandidate.insurer_name ?? '')} / ${String(recommendedCandidate.product_name ?? '')}` : '未設定'}</div>
                        </div>
                        <div style={s.infoCell}>
                            <div style={s.label}>お客様決定プラン</div>
                            <div style={s.value}>{decidedCandidate ? `${String(decidedCandidate.insurer_name ?? '')} / ${String(decidedCandidate.product_name ?? '')}` : '未決定'}</div>
                        </div>
                    </div>
                    {!!run.customer_intent_memo && (
                        <div style={{ marginTop: 4, background: '#f9fafb', border: '1px solid #e5e7eb', borderRadius: 4, padding: '4px 8px', fontSize: 8 }}>
                            <span style={{ fontWeight: 700 }}>意向メモ: </span>{String(run.customer_intent_memo)}
                        </div>
                    )}
                </div>

                {/* Unresolved items */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>未対応事項 / 社内メモ・次回対応</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                        <div>
                            <div style={s.label}>未対応事項</div>
                            {snapshot && (snapshot.unresolved_items as string[]).length > 0 ? (
                                (snapshot.unresolved_items as string[]).map((item, i) => (
                                    <div key={i} style={{ fontSize: 8, color: '#dc2626' }}>・{item}</div>
                                ))
                            ) : (
                                <div style={{ fontSize: 8, color: '#16a34a' }}>なし</div>
                            )}
                        </div>
                        <div>
                            <div style={s.label}>次回対応・社内メモ</div>
                            <div style={{ border: '1px solid #d1d5db', borderRadius: 4, height: 40, padding: 4, fontSize: 8, color: '#9ca3af' }}>
                                （記入欄）
                            </div>
                        </div>
                    </div>
                </div>

                {/* Quality checks */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>業務品質チェック（10項目）</div>
                    <table style={s.table}>
                        <thead>
                            <tr style={{ background: '#374151' }}>
                                <th style={{ ...s.th, width: '5%' }}>#</th>
                                <th style={{ ...s.th, width: '55%' }}>チェック項目</th>
                                <th style={{ ...s.th, width: '15%', textAlign: 'center' }}>判定</th>
                                <th style={{ ...s.th, width: '25%' }}>備考</th>
                            </tr>
                        </thead>
                        <tbody>
                            {qualityChecks.map((qc, i) => (
                                <tr key={i} style={{ background: i % 2 === 0 ? '#f9fafb' : 'white' }}>
                                    <td style={{ ...s.td, textAlign: 'center', color: '#6b7280' }}>{i + 1}</td>
                                    <td style={s.td}>{qc.label}</td>
                                    <td style={{ ...s.td, textAlign: 'center' }}>
                                        <span style={{
                                            fontWeight: 700,
                                            color: qc.pass ? '#15803d' : '#dc2626',
                                            fontSize: 10,
                                        }}>
                                            {qc.pass ? '○' : '✗'}
                                        </span>
                                    </td>
                                    <td style={{ ...s.td, fontSize: 7, color: '#6b7280' }}>{qc.note || '—'}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                    <div style={{ marginTop: 4, fontSize: 7, color: '#6b7280' }}>
                        合計: {qualityChecks.filter(q => q.pass).length}/{qualityChecks.length} 項目合格
                    </div>
                </div>

                <div style={s.pageFooter}>
                    <span>{runRef} - 代理店控え 2/4</span>
                    <span>安心見える化™ [社内管理用]</span>
                </div>
            </div>

            {/* ═══════════════════════════════════════════════════ */}
            {/* PAGE 3 - 重要事項確認内訳・重要証跡タイムライン             */}
            {/* ═══════════════════════════════════════════════════ */}
            <div style={s.page}>
                <div style={s.docHeader}>
                    <div style={{ fontSize: 13, fontWeight: 900 }}>代理店控え - 重要事項確認・証跡タイムライン（監査用）</div>
                    <div style={{ fontSize: 8, color: '#6b7280' }}>{runRef}</div>
                </div>

                {/* Important matters detail */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>重要事項確認内訳（監査用）</div>
                    <table style={s.table}>
                        <thead>
                            <tr style={{ background: '#1e3a5f' }}>
                                <th style={{ ...s.th, width: '40%' }}>確認事項</th>
                                <th style={{ ...s.th, width: '20%', textAlign: 'center' }}>確認方法</th>
                                <th style={{ ...s.th, width: '15%', textAlign: 'center' }}>完了</th>
                                <th style={{ ...s.th, width: '25%' }}>日時・備考</th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr>
                                <td style={s.td}>電子的方法による情報提供への同意確認</td>
                                <td style={{ ...s.td, textAlign: 'center' }}>
                                    {{ agreed: '電子同意', face_confirmed: '面談確認', declined: '紙面交付', not_recorded: '未確認' }[run.electronic_consent_status as string] ?? '—'}
                                </td>
                                <td style={{ ...s.td, textAlign: 'center', fontWeight: 700, color: ['agreed', 'face_confirmed', 'declined'].includes(run.electronic_consent_status as string) ? '#15803d' : '#dc2626' }}>
                                    {['agreed', 'face_confirmed', 'declined'].includes(run.electronic_consent_status as string) ? '○' : '✗'}
                                </td>
                                <td style={{ ...s.td, fontSize: 7 }}>
                                    {run.electronic_consent_confirmed_at ? format(new Date(run.electronic_consent_confirmed_at as string), 'yyyy/M/d HH:mm') : '—'}
                                </td>
                            </tr>
                            <tr style={{ background: '#f9fafb' }}>
                                <td style={s.td}>重要事項説明書の交付</td>
                                <td style={{ ...s.td, textAlign: 'center' }}>
                                    {run.important_matters_delivery_method === 'electronic' ? '電子交付' : run.important_matters_delivery_method === 'paper' ? '書面交付' : '—'}
                                </td>
                                <td style={{ ...s.td, textAlign: 'center', fontWeight: 700, color: run.important_matters_delivered ? '#15803d' : '#dc2626' }}>
                                    {run.important_matters_delivered ? '○' : '✗'}
                                </td>
                                <td style={{ ...s.td, fontSize: 7 }}>
                                    {run.important_matters_delivered_at ? format(new Date(run.important_matters_delivered_at as string), 'yyyy/M/d HH:mm') : '—'}
                                </td>
                            </tr>
                            <tr>
                                <td style={s.td}>スマートフォンによる顧客確認</td>
                                <td style={{ ...s.td, textAlign: 'center' }}>SMS/QR</td>
                                <td style={{ ...s.td, textAlign: 'center', fontWeight: 700, color: run.smartphone_conf_status === 'customer_confirmed' ? '#15803d' : '#dc2626' }}>
                                    {run.smartphone_conf_status === 'customer_confirmed' ? '○' : '✗'}
                                </td>
                                <td style={{ ...s.td, fontSize: 7 }}>
                                    {String(run.smartphone_conf_status ?? '—')}
                                </td>
                            </tr>
                            <tr style={{ background: '#f9fafb' }}>
                                <td style={s.td}>案件確定（スナップショット凍結）</td>
                                <td style={{ ...s.td, textAlign: 'center' }}>システム</td>
                                <td style={{ ...s.td, textAlign: 'center', fontWeight: 700, color: run.finalized_at ? '#15803d' : '#dc2626' }}>
                                    {run.finalized_at ? '○' : '✗'}
                                </td>
                                <td style={{ ...s.td, fontSize: 7 }}>
                                    {run.finalized_at ? format(new Date(run.finalized_at as string), 'yyyy/M/d HH:mm') : '未確定'}
                                </td>
                            </tr>
                            <tr>
                                <td style={s.td}>案件決定プランの確定</td>
                                <td style={{ ...s.td, textAlign: 'center' }}>システム</td>
                                <td style={{ ...s.td, textAlign: 'center', fontWeight: 700, color: run.decided_candidate_id ? '#15803d' : '#dc2626' }}>
                                    {run.decided_candidate_id ? '○' : '✗'}
                                </td>
                                <td style={{ ...s.td, fontSize: 7 }}>
                                    {run.plan_diff_reason_recorded_at ? `差異理由: ${format(new Date(run.plan_diff_reason_recorded_at as string), 'yyyy/M/d HH:mm')}` : (run.decided_candidate_id ? '差異なし' : '未設定')}
                                </td>
                            </tr>
                        </tbody>
                    </table>
                </div>

                {/* Audit timeline */}
                <div style={s.section}>
                    <div style={s.sectionTitle}>重要証跡タイムライン（最大14件）</div>
                    {timeline.length === 0 ? (
                        <div style={{ fontSize: 8, color: '#9ca3af', padding: 8 }}>証跡がありません</div>
                    ) : (
                        <table style={s.table}>
                            <thead>
                                <tr style={{ background: '#1e3a5f' }}>
                                    <th style={{ ...s.th, width: '20%' }}>日時</th>
                                    <th style={{ ...s.th, width: '18%' }}>区分</th>
                                    <th style={{ ...s.th, width: '32%' }}>イベント</th>
                                    <th style={{ ...s.th, width: '30%' }}>補足</th>
                                </tr>
                            </thead>
                            <tbody>
                                {timeline.slice(0, 14).map((entry, i) => (
                                    <tr key={i} style={{ background: i % 2 === 0 ? '#f9fafb' : 'white' }}>
                                        <td style={{ ...s.td, fontSize: 7, fontFamily: 'monospace' }}>
                                            {format(new Date(entry.occurred_at), 'yyyy/M/d HH:mm')}
                                        </td>
                                        <td style={s.td}>
                                            <span style={{
                                                fontSize: 7, padding: '1px 4px', borderRadius: 3, fontWeight: 700,
                                                background: { '現状確認': '#dbeafe', '記録': '#d1fae5', '意向把握': '#fef3c7', '比較・案内': '#f3e8ff', '最終確認': '#fee2e2', '確定': '#dcfce7' }[entry.category] ?? '#f3f4f6',
                                                color: { '現状確認': '#1d4ed8', '記録': '#065f46', '意向把握': '#92400e', '比較・案内': '#6b21a8', '最終確認': '#991b1b', '確定': '#14532d' }[entry.category] ?? '#374151',
                                            }}>
                                                {entry.category}
                                            </span>
                                        </td>
                                        <td style={s.td}>{entry.label}</td>
                                        <td style={{ ...s.td, fontSize: 7, color: '#6b7280' }}>{entry.payload_summary || '—'}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    )}
                </div>

                <div style={s.pageFooter}>
                    <span>{runRef} - 代理店控え 3/4</span>
                    <span>安心見える化™ [社内管理用]</span>
                </div>
            </div>

            {/* ═══════════════════════════════════════════════════ */}
            {/* PAGE 4 - ログ原文全文テーブル                           */}
            {/* ═══════════════════════════════════════════════════ */}
            <div style={s.page}>
                <div style={s.docHeader}>
                    <div style={{ fontSize: 13, fontWeight: 900 }}>代理店控え - ログ原文全文（監査用）</div>
                    <div style={{ fontSize: 8, color: '#6b7280' }}>{runRef}</div>
                </div>

                <div style={s.section}>
                    <div style={s.sectionTitle}>ログ原文全文テーブル</div>
                    {auditEvents.length === 0 ? (
                        <div style={{ fontSize: 8, color: '#9ca3af', padding: 8 }}>監査ログがありません</div>
                    ) : (
                        <table style={s.table}>
                            <thead>
                                <tr style={{ background: '#374151' }}>
                                    <th style={{ ...s.th, width: '5%', textAlign: 'center' }}>No.</th>
                                    <th style={{ ...s.th, width: '18%' }}>日時</th>
                                    <th style={{ ...s.th, width: '77%' }}>ログ原文（event_type / metadata）</th>
                                </tr>
                            </thead>
                            <tbody>
                                {auditEvents.map((ev, i) => (
                                    <tr key={ev.id} style={{ background: i % 2 === 0 ? '#f9fafb' : 'white' }}>
                                        <td style={{ ...s.td, textAlign: 'center', fontSize: 7, color: '#9ca3af' }}>{i + 1}</td>
                                        <td style={{ ...s.td, fontSize: 7, fontFamily: 'monospace', whiteSpace: 'nowrap' }}>
                                            {format(new Date(ev.occurred_at), 'yyyy/M/d HH:mm:ss')}
                                        </td>
                                        <td style={{ ...s.td, fontFamily: 'monospace', fontSize: 7, wordBreak: 'break-all' }}>
                                            <span style={{ fontWeight: 700, color: '#1d4ed8' }}>{ev.event_type}</span>
                                            {ev.payload && Object.keys(ev.payload).length > 0 && (
                                                <span style={{ color: '#6b7280', marginLeft: 6 }}>
                                                    {JSON.stringify(ev.payload)}
                                                </span>
                                            )}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    )}
                </div>

                <div style={s.section}>
                    <div style={s.sectionTitle}>比較プラン一覧（全件）</div>
                    {activePlans.length === 0 ? (
                        <div style={{ fontSize: 8, color: '#9ca3af', padding: 4 }}>なし</div>
                    ) : (
                        <table style={s.table}>
                            <thead>
                                <tr style={{ background: '#374151' }}>
                                    <th style={s.th}>ID</th>
                                    <th style={s.th}>役割</th>
                                    <th style={s.th}>保険会社</th>
                                    <th style={s.th}>商品名</th>
                                    <th style={{ ...s.th, textAlign: 'right' }}>年間保険料</th>
                                    <th style={s.th}>状態</th>
                                    <th style={s.th}>ステータス</th>
                                </tr>
                            </thead>
                            <tbody>
                                {candidates.map((c, i) => (
                                    <tr key={c.id as string} style={{ background: i % 2 === 0 ? '#f9fafb' : 'white' }}>
                                        <td style={{ ...s.td, fontSize: 7, fontFamily: 'monospace' }}>{String(c.id as string).slice(0, 8)}...</td>
                                        <td style={s.td}>{String(c.role ?? '—')}</td>
                                        <td style={s.td}>{String(c.insurer_name ?? '—')}</td>
                                        <td style={s.td}>{String(c.product_name ?? '—')}</td>
                                        <td style={{ ...s.td, textAlign: 'right' }}>
                                            {c.annual_premium ? `¥${Number(c.annual_premium).toLocaleString()}` : '—'}
                                        </td>
                                        <td style={s.td}>{{ full: '○ あり', partial: '△ 一部', none: '× なし' }[c.coverage_status as string] ?? '—'}</td>
                                        <td style={s.td}>
                                            <span style={{ fontWeight: 700, color: c.status === 'active' ? '#15803d' : '#6b7280' }}>
                                                {String(c.status ?? '—')}
                                            </span>
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    )}
                </div>

                <div style={s.pageFooter}>
                    <span>{runRef} - 代理店控え 4/4</span>
                    <span>安心見える化™ [社内管理用] 印刷日: {printedAt}</span>
                </div>
            </div>
        </div>
    )
}

export default function AgencyReportPage() {
    return (
        <Suspense fallback={<div style={s.loading}>読み込み中...</div>}>
            <AgencyReportContent />
        </Suspense>
    )
}

const s: Record<string, React.CSSProperties> = {
    root: { fontFamily: '"Hiragino Kaku Gothic ProN","Meiryo","Yu Gothic",sans-serif', background: '#e5e7eb', padding: 20 },
    loading: { display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', fontFamily: 'sans-serif', color: '#6b7280' },
    noPrint: { display: 'flex', gap: 8, marginBottom: 16, justifyContent: 'flex-end' },
    printBtn: { padding: '8px 20px', background: '#374151', color: 'white', border: 'none', borderRadius: 6, cursor: 'pointer', fontSize: 13, fontWeight: 700 },
    backBtn: { padding: '8px 16px', background: 'white', color: '#374151', border: '1px solid #d1d5db', borderRadius: 6, cursor: 'pointer', fontSize: 13 },
    page: {
        width: '210mm', minHeight: '297mm', background: 'white', margin: '0 auto 20px',
        padding: '10mm 14mm', boxSizing: 'border-box', position: 'relative',
        boxShadow: '0 2px 12px rgba(0,0,0,0.12)',
        pageBreakAfter: 'always',
    },
    docHeader: { display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 8, borderBottom: '2px solid #374151', paddingBottom: 6 },
    section: { marginBottom: 8 },
    sectionTitle: { fontSize: 9, fontWeight: 900, color: 'white', background: '#374151', padding: '3px 8px', marginBottom: 4, letterSpacing: '0.05em' },
    grid3: { display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 },
    card: { border: '1px solid #e5e7eb', borderRadius: 4, padding: '5px 8px' },
    cardLabel: { fontSize: 7, color: '#6b7280', fontWeight: 700, marginBottom: 2 },
    cardValue: { fontSize: 10, fontWeight: 700, color: '#111827', marginBottom: 2 },
    cardSub: { fontSize: 8, color: '#374151' },
    infoGrid3: { display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '4px 12px' },
    infoCell: { padding: '2px 0' },
    label: { fontSize: 7, color: '#6b7280', marginBottom: 1 },
    value: { fontSize: 9, fontWeight: 500, color: '#111827' },
    table: { width: '100%', borderCollapse: 'collapse', fontSize: 8 },
    th: { padding: '3px 5px', textAlign: 'left', color: 'white', fontWeight: 700, fontSize: 7, borderRight: '1px solid rgba(255,255,255,0.2)' },
    td: { padding: '3px 5px', borderBottom: '1px solid #e5e7eb', borderRight: '1px solid #f3f4f6', fontSize: 8, verticalAlign: 'top' },
    axisLabel: { fontSize: 6, fontWeight: 400, opacity: 0.8, marginTop: 1 },
    statusCard: { border: '1.5px solid', borderRadius: 4, padding: '5px 8px' },
    pageFooter: { position: 'absolute', bottom: '6mm', left: '14mm', right: '14mm', display: 'flex', justifyContent: 'space-between', fontSize: 7, color: '#9ca3af', borderTop: '1px solid #e5e7eb', paddingTop: 4 },
}
