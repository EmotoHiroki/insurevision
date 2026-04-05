'use client'

import React, { useEffect, useState, useCallback } from 'react'
import { useRouter, useParams, useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import type { Run, Candidate, Operator, AuditEvent, Snapshot, CoverageStatus } from '@/lib/types'
import { t as i18nT } from '@/lib/i18n'
import { format } from 'date-fns'
import {
    LuShield, LuGlobe, LuArrowLeft, LuCheck, LuPlus, LuTrash2,
    LuClock, LuUser, LuRefreshCw, LuFileText, LuChartBar, LuLock,
    LuCircleCheck, LuCircleX,
} from 'react-icons/lu'

// ─────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────
type TabKey = 'overview' | 'comparison' | 'finalize' | 'audit'

// ─────────────────────────────────────────────
// D-C: RedundancyRow sub-component
// ─────────────────────────────────────────────
function RedundancyRow({ item, isEditable, locale, saving, onSave, onRemove }: {
    item: { item_key: string; decision: 'keep' | 'remove'; reason: string }
    isEditable: boolean
    locale: string
    saving: boolean
    onSave: (key: string, decision: 'keep' | 'remove', reason: string) => void
    onRemove: (key: string) => void
}) {
    const [decision, setDecision] = React.useState<'keep' | 'remove'>(item.decision)
    const [reason, setReason] = React.useState(item.reason)

    return (
        <div style={{ border: '1px solid #e2e8f0', borderRadius: 8, padding: '12px 14px', marginBottom: 10 }}>
            <div style={{ fontWeight: 600, fontSize: 13, marginBottom: 8 }}>{item.item_key}</div>
            <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
                {(['keep', 'remove'] as const).map(opt => (
                    <button key={opt} disabled={!isEditable}
                        onClick={() => setDecision(opt)}
                        style={{
                            padding: '4px 12px', fontSize: 12, borderRadius: 6, cursor: isEditable ? 'pointer' : 'default',
                            border: `1px solid ${decision === opt ? (opt === 'keep' ? '#16a34a' : '#dc2626') : '#e2e8f0'}`,
                            background: decision === opt ? (opt === 'keep' ? '#dcfce7' : '#fee2e2') : 'white',
                            color: decision === opt ? (opt === 'keep' ? '#15803d' : '#dc2626') : 'var(--text-secondary)',
                            fontWeight: decision === opt ? 700 : 400,
                        }}>
                        {opt === 'keep' ? (locale === 'ja' ? '継続する' : 'Keep') : (locale === 'ja' ? '削除して見直す' : 'Remove')}
                    </button>
                ))}
            </div>
            <input value={reason} onChange={e => setReason(e.target.value)} disabled={!isEditable}
                placeholder={locale === 'ja' ? '理由を入力' : 'Enter reason'}
                style={{ width: '100%', padding: '6px 10px', borderRadius: 6, border: '1px solid #e2e8f0', fontSize: 12, marginBottom: 8 }} />
            {isEditable && (
                <div style={{ display: 'flex', gap: 6 }}>
                    <button disabled={saving} onClick={() => onSave(item.item_key, decision, reason)}
                        style={{ fontSize: 12, padding: '4px 10px', borderRadius: 6, border: '1px solid #cbd5e1', background: 'white', cursor: 'pointer' }}>
                        {locale === 'ja' ? '保存' : 'Save'}
                    </button>
                    <button onClick={() => onRemove(item.item_key)}
                        style={{ fontSize: 12, padding: '4px 10px', borderRadius: 6, border: '1px solid var(--error)', color: 'var(--error)', background: 'white', cursor: 'pointer' }}>
                        {locale === 'ja' ? '削除' : 'Delete'}
                    </button>
                </div>
            )}
        </div>
    )
}

export default function RunDetailPage() {
    const router = useRouter()
    const params = useParams()
    const runId = params.id as string
    const { toggleLocale, locale } = useLocale()

    const [run, setRun] = useState<Run | null>(null)
    const [snapshot, setSnapshot] = useState<Snapshot | null>(null)
    const [candidates, setCandidates] = useState<Candidate[]>([])
    const [auditEvents, setAuditEvents] = useState<AuditEvent[]>([])
    const [operator, setOperator] = useState<Operator | null>(null)
    const [loading, setLoading] = useState(true)
    const [saving, setSaving] = useState(false)
    const [error, setError] = useState('')
    const [toast, setToast] = useState<{ msg: string; type: 'success' | 'error' } | null>(null)

    const searchParams = useSearchParams()
    const urlTab = searchParams.get('tab') as TabKey | null
    const [activeTab, setActiveTab] = useState<TabKey>(urlTab || 'overview')

    // Candidate form state (comparison tab)
    const [newInsurerName, setNewInsurerName] = useState('')
    const [newProductName, setNewProductName] = useState('')
    const [newPremium, setNewPremium] = useState('')

    // Exclusion inline form
    const [excludingId, setExcludingId] = useState<string | null>(null)
    const [exclusionReason, setExclusionReason] = useState('')

    // Finalize tab
    const [consentComparisonResult, setConsentComparisonResult] = useState(false)
    const [finalizing, setFinalizing] = useState(false)
    // M2 Spec 2: 課題解消メモ
    const [resolutionMemo, setResolutionMemo] = useState('')
    const [savingMemo, setSavingMemo] = useState(false)
    // M2 Spec 1: coverage_status update
    const [updatingCoverage, setUpdatingCoverage] = useState<string | null>(null)
    // D-B: delivery record
    const [deliveryMethod, setDeliveryMethod] = useState<string>('')
    const [deliveryConfirmed, setDeliveryConfirmed] = useState(false)
    const [savingDelivery, setSavingDelivery] = useState(false)
    // D-C: redundancy decisions
    const [redundancyDecisions, setRedundancyDecisions] = useState<Array<{ item_key: string; decision: 'keep' | 'remove'; reason: string }>>([])
    const [newRedundancyItem, setNewRedundancyItem] = useState('')
    const [savingRedundancy, setSavingRedundancy] = useState(false)
    // Suspension
    const [showSuspendForm, setShowSuspendForm] = useState(false)
    const [suspensionType, setSuspensionType] = useState<'condition_adjustment' | 'mid_session'>('condition_adjustment')
    const [pendingNote, setPendingNote] = useState('')
    const [suspending, setSuspending] = useState(false)

    // ─────────────────────────────────────────────
    const showToast = (msg: string, type: 'success' | 'error' = 'success') => {
        setToast({ msg, type })
        setTimeout(() => setToast(null), 3000)
    }

    const loadData = useCallback(async () => {
        setLoading(true)
        const supabase = createClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) { router.push('/login'); return }

        const { data: opData } = await supabase.from('operator').select('*').eq('auth_user_id', user.id).maybeSingle()
        if (opData) setOperator(opData)

        const { data: runData } = await supabase.from('run').select('*').eq('id', runId).single()
        if (runData) setRun(runData as Run)

        const { data: snapData } = await supabase.from('snapshot').select('*').eq('run_id', runId).maybeSingle()
        if (snapData) {
            setSnapshot(snapData as Snapshot)
            setResolutionMemo((snapData as Snapshot).resolution_memo ?? '')
            setRedundancyDecisions((snapData as Snapshot).redundancy_decisions ?? [])
        }
        if (runData) {
            setDeliveryMethod((runData as Run).delivery_method ?? '')
            setDeliveryConfirmed(!!(runData as Run).delivery_confirmed_at)
        }

        const { data: candData } = await supabase.from('candidate').select('*').eq('run_id', runId).order('slot_no')
        setCandidates((candData as Candidate[]) || [])

        const { data: auditData } = await supabase
            .from('audit_event').select('*').eq('run_id', runId).order('occurred_at', { ascending: true })
        setAuditEvents((auditData as AuditEvent[]) || [])

        setLoading(false)
    }, [runId, router])

    useEffect(() => { loadData() }, [loadData])

    // ─────────────────────────────────────────────
    // Comparison tab actions
    // ─────────────────────────────────────────────
    const handleAddCandidate = async () => {
        if (!newInsurerName.trim() || !run) return
        setSaving(true)
        try {
            const supabase = createClient()
            const nextSlot = candidates.length > 0 ? Math.max(...candidates.map(c => c.slot_no)) + 1 : 1
            const { data, error: err } = await supabase.from('candidate').insert({
                run_id: runId,
                slot_no: nextSlot,
                insurer_name: newInsurerName.trim(),
                product_name: newProductName.trim() || null,
                annual_premium: newPremium ? parseInt(newPremium) : null,
                status: 'active',
            }).select().single()
            if (err) throw err
            if (!data) throw new Error('候補の追加に失敗しました / Failed to add candidate')
            setCandidates(prev => [...prev, data as Candidate])
            setNewInsurerName('')
            setNewProductName('')
            setNewPremium('')
            showToast(locale === 'ja' ? '候補を追加しました' : 'Candidate added')
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSaving(false) }
    }

    const handleExcludeCandidate = async (candidateId: string) => {
        if (!operator || !exclusionReason.trim()) return
        setSaving(true)
        try {
            const supabase = createClient()
            await supabase.from('candidate').update({
                status: 'excluded',
                excluded_reason: exclusionReason.trim(),
                excluded_by: operator.id,
                excluded_at: new Date().toISOString(),
            }).eq('id', candidateId)

            await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: 'exclusion_reason_recorded',
                operator_id: operator.id,
                payload: { candidate_id: candidateId, reason: exclusionReason.trim() },
            })

            setExcludingId(null)
            setExclusionReason('')
            await loadData()
            showToast(locale === 'ja' ? '除外しました' : 'Candidate excluded')
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSaving(false) }
    }

    const handleStartPresenting = async () => {
        if (!operator || !run) return
        if (run.compare_presented_at) return   // already presented
        setSaving(true)
        try {
            const supabase = createClient()
            const now = new Date().toISOString()
            await supabase.from('run').update({ compare_presented_at: now }).eq('id', runId)
            await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: 'compare_presented',
                operator_id: operator.id,
                payload: { presented_at: now },
            })
            await loadData()
            showToast(locale === 'ja' ? '比較提示を記録しました' : 'Compare presentation recorded')
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSaving(false) }
    }

    // M2 D-A: add recommended candidate (same_insurer)
    const handleAddRecommended = async () => {
        if (!run) return
        const ROLES = ['recommended_1', 'recommended_2', 'recommended_3'] as const
        const nextRole = ROLES.find(r => !candidates.some(c => c.role === r))
        if (!nextRole) return
        setSaving(true)
        try {
            const supabase = createClient()
            const nextSlot = candidates.length > 0 ? Math.max(...candidates.map(c => c.slot_no)) + 1 : 1
            const { data, error: err } = await supabase.from('candidate').insert({
                run_id: runId,
                slot_no: nextSlot,
                insurer_name: '',
                role: nextRole,
                status: 'active',
            }).select().single()
            if (err) throw err
            setCandidates(prev => [...prev, data as Candidate])
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSaving(false) }
    }

    // M2 Spec 1: update coverage_status on a candidate
    const handleUpdateCoverageStatus = async (candidateId: string, status: CoverageStatus) => {
        setUpdatingCoverage(candidateId)
        const supabase = createClient()
        await supabase.from('candidate').update({ coverage_status: status }).eq('id', candidateId)
        setCandidates(prev => prev.map(c => c.id === candidateId ? { ...c, coverage_status: status } : c))
        setUpdatingCoverage(null)
    }

    // D-B: save delivery record
    const handleSaveDelivery = async () => {
        if (!operator) return
        setSavingDelivery(true)
        const supabase = createClient()
        const now = new Date().toISOString()
        await supabase.from('run').update({
            delivery_method: deliveryMethod || null,
            delivery_confirmed_at: deliveryConfirmed ? now : null,
        }).eq('id', runId)
        if (deliveryConfirmed) {
            await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: 'delivery_recorded' as const,
                operator_id: operator.id,
                payload: { delivery_method: deliveryMethod, confirmed_at: now },
            })
        }
        setSavingDelivery(false)
        showToast(locale === 'ja' ? '交付記録を保存しました' : 'Delivery record saved')
        await loadData()
    }

    // D-C: save redundancy decision
    const handleSaveRedundancyDecision = async (
        itemKey: string, decision: 'keep' | 'remove', reason: string
    ) => {
        if (!operator || !snapshot) return
        setSavingRedundancy(true)
        const updated = redundancyDecisions.filter(d => d.item_key !== itemKey)
        updated.push({ item_key: itemKey, decision, reason })
        const supabase = createClient()
        await supabase.from('snapshot').update({ redundancy_decisions: updated }).eq('id', snapshot.id)
        await supabase.from('audit_event').insert({
            run_id: runId,
            event_type: 'redundancy_resolution_recorded' as const,
            operator_id: operator.id,
            payload: { item_key: itemKey, decision, reason },
        })
        setRedundancyDecisions(updated)
        setSavingRedundancy(false)
        showToast(locale === 'ja' ? '判断を保存しました' : 'Decision saved')
    }

    const handleRemoveRedundancyItem = async (itemKey: string) => {
        if (!snapshot) return
        const updated = redundancyDecisions.filter(d => d.item_key !== itemKey)
        const supabase = createClient()
        await supabase.from('snapshot').update({ redundancy_decisions: updated }).eq('id', snapshot.id)
        setRedundancyDecisions(updated)
    }

    // Suspension
    const handleSuspend = async () => {
        if (!operator) return
        setSuspending(true)
        const supabase = createClient()
        await supabase.from('run').update({
            run_status: 'suspended',
            suspension_type: suspensionType,
            pending_note: pendingNote.trim() || null,
            suspended_at: new Date().toISOString(),
        }).eq('id', runId)
        setSuspending(false)
        setShowSuspendForm(false)
        showToast(locale === 'ja' ? '案件を保留にしました' : 'Run suspended')
        await loadData()
    }

    const handleResume = async () => {
        const supabase = createClient()
        await supabase.from('run').update({
            run_status: 'draft',
            suspension_type: null,
            pending_note: null,
            suspended_at: null,
        }).eq('id', runId)
        showToast(locale === 'ja' ? '案件を再開しました' : 'Run resumed')
        await loadData()
    }

    // ─────────────────────────────────────────────
    // Finalize
    // ─────────────────────────────────────────────
    const handleFinalize = async () => {
        if (!operator || !run) return
        setFinalizing(true)
        setError('')
        try {
            const res = await fetch('/api/finalize', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    runId,
                    operatorId: operator.id,
                    consentFlags: {
                        comparison_result: consentComparisonResult,
                        important_matters: false,
                        personal_info: false,
                    },
                    exceptionRoute: false,
                }),
            })
            const body = await res.json()
            if (!res.ok) throw new Error(body.error ?? 'Finalize failed')
            showToast(i18nT(locale, 'finalizeSuccess'))
            await loadData()
        } catch (e: unknown) {
            setError(e instanceof Error ? e.message : 'Error')
        } finally { setFinalizing(false) }
    }

    // ─────────────────────────────────────────────
    // Pre-flight checks
    // ─────────────────────────────────────────────
    const preflightChecks = run ? [
        {
            id: 'snapshot_resolved',
            labelJa: '全フラグ解決済み（Fail-Closed）',
            labelEn: 'All flags resolved (Fail-Closed)',
            pass: !snapshot || snapshot.unresolved_items.length === 0,
        },
        {
            id: 'customer_decision',
            labelJa: '顧客判断が記録されている',
            labelEn: 'Customer decision is recorded',
            pass: !!run.customer_decision,
        },
        {
            id: 'candidates_exist',
            labelJa: '候補が1件以上存在する（比較経路）',
            labelEn: 'At least one candidate exists (compare path)',
            pass: run.customer_decision !== 'compare' || candidates.filter(c => c.status === 'active').length > 0,
        },
        {
            id: 'compare_presented',
            labelJa: '比較提示が記録されている（比較経路）',
            labelEn: 'Compare presentation recorded (compare path)',
            pass: run.customer_decision !== 'compare' || !!run.compare_presented_at,
        },
        // M2 Spec 5: insurer_list_presented must be recorded
        {
            id: 'insurer_list_presented',
            labelJa: '取扱保険会社案内が記録されている',
            labelEn: 'Insurer list presentation recorded',
            pass: auditEvents.some(e => e.event_type === 'insurer_list_presented'),
        },
    ] : []

    const allPreflightPass = preflightChecks.every(c => c.pass)

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────
    const statusLabel = (s: string) => {
        const map: Record<string, { ja: string; en: string }> = {
            draft: { ja: '下書き', en: 'Draft' },
            finalized: { ja: '確定済（編集不可）', en: 'Confirmed (Read-only)' },
            archived: { ja: 'アーカイブ', en: 'Archived' },
            suspended: { ja: '保留中', en: 'Suspended' },
        }
        return locale === 'ja' ? (map[s]?.ja ?? s) : (map[s]?.en ?? s)
    }

    const auditEventColor = (eventType: string) => {
        if (eventType === 'run_finalized') return { bg: 'rgba(46,125,50,0.1)', color: '#2e7d32' }
        if (eventType === 'compare_presented') return { bg: 'rgba(2,119,189,0.1)', color: '#0277bd' }
        if (eventType.startsWith('consent_')) return { bg: 'rgba(0,131,143,0.1)', color: '#00838f' }
        if (eventType === 'manual_review_completed') return { bg: 'rgba(239,108,0,0.1)', color: '#ef6c00' }
        if (eventType === 'issue_shared') return { bg: 'rgba(0,0,0,0.06)', color: '#555' }
        return { bg: 'rgba(0,0,0,0.06)', color: '#666' }
    }

    // ─────────────────────────────────────────────
    if (loading || !run) {
        return (
            <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'var(--surface)' }}>
                <span className="animate-pulse-soft" style={{ fontSize: 16, color: 'var(--text-secondary)' }}>
                    {i18nT(locale, 'loading')}
                </span>
            </div>
        )
    }

    const isEditable = run.run_status === 'draft'
    const activeCandidates = candidates.filter(c => c.status === 'active')

    const TABS: Array<{ key: TabKey; labelJa: string; labelEn: string; icon: React.ElementType }> = [
        { key: 'overview', labelJa: '概要', labelEn: 'Overview', icon: LuUser },
        { key: 'comparison', labelJa: '比較', labelEn: 'Comparison', icon: LuChartBar },
        { key: 'finalize', labelJa: '確定', labelEn: 'Finalize', icon: LuLock },
        { key: 'audit', labelJa: '監査ログ', labelEn: 'Audit', icon: LuClock },
    ]

    return (
        <div style={{ minHeight: '100vh', background: 'var(--surface)' }}>
            {/* Header */}
            <header style={{
                background: 'var(--primary)', color: 'white', padding: '0 24px', height: 56,
                display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                boxShadow: '0 2px 8px rgba(0,0,0,0.15)',
            }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                    <button onClick={() => router.push('/dashboard')} style={{
                        background: 'rgba(255,255,255,0.1)', border: 'none', color: 'white',
                        padding: '6px 10px', borderRadius: 6, cursor: 'pointer',
                    }}>
                        <LuArrowLeft size={18} />
                    </button>
                    <LuShield size={18} />
                    <span style={{ fontWeight: 600 }}>{run.customer_ref}</span>
                    <span className={`status-${run.run_status}`} style={{
                        padding: '3px 10px', borderRadius: 10, fontSize: 12, fontWeight: 600, marginLeft: 8,
                    }}>
                        {statusLabel(run.run_status)}
                    </span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <button onClick={toggleLocale} style={{
                        background: 'rgba(255,255,255,0.1)', border: 'none', color: 'rgba(255,255,255,0.8)',
                        padding: '6px 12px', borderRadius: 6, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 4, fontSize: 12,
                    }}>
                        <LuGlobe size={14} /> {locale === 'ja' ? 'EN' : 'JA'}
                    </button>
                    <button onClick={loadData} style={{
                        background: 'rgba(255,255,255,0.1)', border: 'none', color: 'white',
                        padding: '6px 10px', borderRadius: 6, cursor: 'pointer',
                    }}>
                        <LuRefreshCw size={16} />
                    </button>
                </div>
            </header>

            <div style={{ maxWidth: 1280, margin: '0 auto', padding: 28 }}>
                {/* Tabs */}
                <div style={{
                    display: 'flex', gap: 4, marginBottom: 24, background: 'white',
                    borderRadius: 10, padding: 4, boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
                }}>
                    {TABS.map(tab => (
                        <button
                            key={tab.key}
                            onClick={() => setActiveTab(tab.key)}
                            style={{
                                flex: 1, padding: '10px 16px', border: 'none', borderRadius: 8, cursor: 'pointer',
                                fontWeight: 500, fontSize: 14, display: 'flex', alignItems: 'center',
                                justifyContent: 'center', gap: 8,
                                background: activeTab === tab.key ? 'var(--primary)' : 'transparent',
                                color: activeTab === tab.key ? 'white' : 'var(--text-secondary)',
                            }}
                        >
                            <tab.icon size={16} />
                            {locale === 'ja' ? tab.labelJa : tab.labelEn}
                        </button>
                    ))}
                </div>

                {/* ═══════════════════════════════════════ */}
                {/* TAB: OVERVIEW                           */}
                {/* ═══════════════════════════════════════ */}
                {activeTab === 'overview' && (
                    <div className="animate-fade-in" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                        {/* Basic info */}
                        <div className="section-card">
                            <h3 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16, display: 'flex', alignItems: 'center', gap: 8 }}>
                                <LuUser size={18} color="var(--primary)" />
                                {i18nT(locale, 'basicInfo')}
                            </h3>
                            <dl style={{ display: 'grid', gap: 10 }}>
                                <div><dt className="form-label">{i18nT(locale, 'customerRef')}</dt><dd style={{ fontWeight: 600 }}>{run.customer_ref}</dd></div>
                                {run.customer_name && <div><dt className="form-label">{locale === 'ja' ? '顧客名' : 'Customer Name'}</dt><dd style={{ fontWeight: 600 }}>{run.customer_name}</dd></div>}
                                <div><dt className="form-label">{i18nT(locale, 'customerType')}</dt><dd>{run.customer_type === 'individual' ? i18nT(locale, 'individual') : i18nT(locale, 'corporate')}</dd></div>
                                {run.customer_type === 'corporate' && run.corporate_decision_maker && (
                                    <div><dt className="form-label">{locale === 'ja' ? '法人意思決定者' : 'Decision Maker'}</dt><dd>{run.corporate_decision_maker}</dd></div>
                                )}
                                <div><dt className="form-label">{i18nT(locale, 'runType')}</dt><dd>{run.run_type === 'new_contract' ? i18nT(locale, 'newContract') : i18nT(locale, 'renewal')}</dd></div>
                                {run.intent_confirmed_with && <div><dt className="form-label">{locale === 'ja' ? '意向確認相手' : 'Intent Confirmed With'}</dt><dd>{run.intent_confirmed_with}</dd></div>}
                                <div><dt className="form-label">{i18nT(locale, 'createdAt')}</dt><dd style={{ fontSize: 13 }}>{format(new Date(run.created_at), 'yyyy/MM/dd HH:mm')}</dd></div>
                            </dl>
                        </div>

                        {/* Decision & Status */}
                        <div className="section-card">
                            <h3 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16, display: 'flex', alignItems: 'center', gap: 8 }}>
                                <LuFileText size={18} color="var(--primary)" />
                                {locale === 'ja' ? '判断・ステータス' : 'Decision & Status'}
                            </h3>
                            <dl style={{ display: 'grid', gap: 10 }}>
                                <div>
                                    <dt className="form-label">{i18nT(locale, 'status')}</dt>
                                    <dd>
                                        <span className={`status-${run.run_status}`} style={{ padding: '4px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600 }}>
                                            {statusLabel(run.run_status)}
                                        </span>
                                    </dd>
                                </div>
                                <div>
                                    <dt className="form-label">{locale === 'ja' ? '顧客判断' : 'Customer Decision'}</dt>
                                    <dd>{run.customer_decision
                                        ? ({
                                            compare: i18nT(locale, 'decisionCompare'),
                                            renewal_no_change: i18nT(locale, 'decisionRenewalNoChange'),
                                            information_refused: i18nT(locale, 'decisionInformationRefused'),
                                            comparison_waived: i18nT(locale, 'decisionComparisonWaived'),
                                        }[run.customer_decision] ?? run.customer_decision)
                                        : '—'}</dd>
                                </div>
                                {run.compliance_mode && (
                                    <div>
                                        <dt className="form-label">{i18nT(locale, 'complianceMode')}</dt>
                                        <dd>{run.compliance_mode === 'full' ? i18nT(locale, 'complianceFull') : i18nT(locale, 'complianceException')}</dd>
                                    </div>
                                )}
                                {run.finalized_at && (
                                    <div>
                                        <dt className="form-label">{i18nT(locale, 'finalizedAt')}</dt>
                                        <dd style={{ fontSize: 13 }}>{format(new Date(run.finalized_at), 'yyyy/MM/dd HH:mm')}</dd>
                                    </div>
                                )}
                            </dl>
                        </div>

                        {/* Intent memo */}
                        {run.customer_intent_memo && (
                            <div className="section-card" style={{ gridColumn: '1 / -1' }}>
                                <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>
                                    {i18nT(locale, 'customerIntentMemo')}
                                </h3>
                                <p style={{ background: '#f9fafb', padding: 12, borderRadius: 8, fontSize: 14 }}>
                                    {run.customer_intent_memo}
                                </p>
                            </div>
                        )}

                        {/* Snapshot summary */}
                        {snapshot && (
                            <div className="section-card" style={{ gridColumn: '1 / -1' }}>
                                <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>
                                    {locale === 'ja' ? '診断スナップショット' : 'Diagnosis Snapshot'}
                                </h3>
                                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
                                    <div style={{ background: '#fef2f2', padding: 12, borderRadius: 8 }}>
                                        <div style={{ fontSize: 12, color: '#991b1b', marginBottom: 4 }}>{i18nT(locale, 'missingFlags')}</div>
                                        <div style={{ fontWeight: 700, fontSize: 18 }}>{snapshot.missing_flags.length}</div>
                                    </div>
                                    <div style={{ background: '#fffbeb', padding: 12, borderRadius: 8 }}>
                                        <div style={{ fontSize: 12, color: '#92400e', marginBottom: 4 }}>{i18nT(locale, 'uncertainFlags')}</div>
                                        <div style={{ fontWeight: 700, fontSize: 18 }}>{snapshot.uncertain_flags.length}</div>
                                    </div>
                                    <div style={{ background: snapshot.unresolved_items.length > 0 ? '#fef2f2' : '#f0fdf4', padding: 12, borderRadius: 8 }}>
                                        <div style={{ fontSize: 12, color: snapshot.unresolved_items.length > 0 ? '#991b1b' : '#14532d', marginBottom: 4 }}>
                                            {i18nT(locale, 'unresolvedItems')}
                                        </div>
                                        <div style={{ fontWeight: 700, fontSize: 18 }}>{snapshot.unresolved_items.length}</div>
                                    </div>
                                </div>
                            </div>
                        )}

                        {/* Suspension banner */}
                        {run.run_status === 'suspended' && (
                            <div className="section-card" style={{ gridColumn: '1 / -1', background: '#fffbeb', borderColor: '#fbbf24' }}>
                                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                                    <div>
                                        <p style={{ fontWeight: 700, color: '#92400e', marginBottom: 4 }}>
                                            {locale === 'ja' ? '保留中' : 'Suspended'} —
                                            {run.suspension_type === 'condition_adjustment'
                                                ? (locale === 'ja' ? ' 条件調整保留' : ' Condition Adjustment')
                                                : (locale === 'ja' ? ' 中途保留' : ' Mid-Session')}
                                        </p>
                                        {run.pending_note && <p style={{ fontSize: 13, color: '#92400e' }}>{run.pending_note}</p>}
                                        {run.suspended_at && <p style={{ fontSize: 12, color: '#b45309' }}>{new Date(run.suspended_at).toLocaleString()}</p>}
                                    </div>
                                    <button className="btn-primary" onClick={handleResume} style={{ fontSize: 13 }}>
                                        {locale === 'ja' ? '保留を解除して再開' : 'Resume'}
                                    </button>
                                </div>
                            </div>
                        )}

                        {/* Suspend button */}
                        {isEditable && (
                            <div style={{ gridColumn: '1 / -1' }}>
                                {!showSuspendForm ? (
                                    <button className="btn-secondary" onClick={() => setShowSuspendForm(true)} style={{ fontSize: 13 }}>
                                        {locale === 'ja' ? '案件を保留にする' : 'Suspend Run'}
                                    </button>
                                ) : (
                                    <div className="section-card" style={{ borderColor: '#fbbf24', background: '#fffbeb' }}>
                                        <p style={{ fontWeight: 600, marginBottom: 12, color: '#92400e' }}>
                                            {locale === 'ja' ? '保留の種別を選択してください' : 'Select suspension type'}
                                        </p>
                                        <div style={{ display: 'flex', gap: 12, marginBottom: 12 }}>
                                            {([
                                                { value: 'condition_adjustment' as const, ja: '条件調整保留', en: 'Condition Adjustment', desc: locale === 'ja' ? 'チェック完了後に条件を再確認' : 'Full checklist done, reviewing conditions' },
                                                { value: 'mid_session' as const, ja: '中途保留', en: 'Mid-Session', desc: locale === 'ja' ? '面談途中で中断' : 'Stopped partway through meeting' },
                                            ]).map(opt => (
                                                <label key={opt.value} style={{
                                                    flex: 1, padding: '10px 14px', border: `2px solid ${suspensionType === opt.value ? '#f59e0b' : '#e2e8f0'}`,
                                                    borderRadius: 8, cursor: 'pointer', background: suspensionType === opt.value ? '#fef3c7' : 'white',
                                                }}>
                                                    <input type="radio" name="suspensionType" value={opt.value}
                                                        checked={suspensionType === opt.value}
                                                        onChange={() => setSuspensionType(opt.value)}
                                                        style={{ marginRight: 8 }} />
                                                    <span style={{ fontWeight: 600, fontSize: 13 }}>{locale === 'ja' ? opt.ja : opt.en}</span>
                                                    <p style={{ fontSize: 11, color: '#78716c', marginTop: 4 }}>{opt.desc}</p>
                                                </label>
                                            ))}
                                        </div>
                                        <textarea value={pendingNote} onChange={e => setPendingNote(e.target.value)}
                                            rows={2} placeholder={locale === 'ja' ? '保留メモ（任意）' : 'Suspension note (optional)'}
                                            style={{ width: '100%', padding: '8px 10px', borderRadius: 8, border: '1px solid #e2e8f0', fontSize: 13, resize: 'none', marginBottom: 10 }} />
                                        <div style={{ display: 'flex', gap: 8 }}>
                                            <button className="btn-primary" onClick={handleSuspend} disabled={suspending} style={{ fontSize: 13, background: '#f59e0b', borderColor: '#f59e0b' }}>
                                                {suspending ? '...' : (locale === 'ja' ? '保留にする' : 'Suspend')}
                                            </button>
                                            <button className="btn-secondary" onClick={() => setShowSuspendForm(false)} style={{ fontSize: 13 }}>
                                                {locale === 'ja' ? 'キャンセル' : 'Cancel'}
                                            </button>
                                        </div>
                                    </div>
                                )}
                            </div>
                        )}

                        {/* Archive button */}
                        {run.run_status === 'finalized' && (
                            <div style={{ gridColumn: '1 / -1', display: 'flex', justifyContent: 'flex-end' }}>
                                <button
                                    className="btn-secondary"
                                    disabled={saving}
                                    onClick={async () => {
                                        if (!confirm(locale === 'ja' ? 'アーカイブしますか？' : 'Archive this run?')) return
                                        const supabase = createClient()
                                        await supabase.from('run').update({ run_status: 'archived' }).eq('id', runId)
                                        await loadData()
                                    }}
                                >
                                    {locale === 'ja' ? 'アーカイブ' : 'Archive'}
                                </button>
                            </div>
                        )}
                    </div>
                )}

                {/* ═══════════════════════════════════════ */}
                {/* TAB: COMPARISON                         */}
                {/* ═══════════════════════════════════════ */}
                {activeTab === 'comparison' && (
                    <div className="animate-fade-in space-y-6">
                        {!run.comparison_scope && (
                            <div className="section-card" style={{ background: '#fffbeb', borderColor: '#fbbf24' }}>
                                <p style={{ color: '#92400e', fontSize: 14 }}>
                                    {locale === 'ja'
                                        ? '比較範囲がまだ設定されていません。案件の新規作成フローでStep4を完了してください。'
                                        : 'Comparison scope not set. Complete Step 4 in the new run wizard.'}
                                </p>
                            </div>
                        )}

                        {/* Start presenting button */}
                        {isEditable && run.comparison_scope && (
                            <div className="section-card" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                                <div>
                                    <p style={{ fontWeight: 600, marginBottom: 4 }}>
                                        {locale === 'ja' ? '比較提示' : 'Start Presenting'}
                                    </p>
                                    <p style={{ fontSize: 13, color: 'var(--text-secondary)' }}>
                                        {run.compare_presented_at
                                            ? `${locale === 'ja' ? '提示日時: ' : 'Presented: '}${format(new Date(run.compare_presented_at), 'yyyy/MM/dd HH:mm')}`
                                            : (locale === 'ja' ? '顧客への比較提示を開始します' : 'Record that comparison was presented to the customer')}
                                    </p>
                                </div>
                                {!run.compare_presented_at && (
                                    <button className="btn-primary" onClick={handleStartPresenting} disabled={saving}>
                                        {i18nT(locale, 'beginPresenting')}
                                    </button>
                                )}
                                {run.compare_presented_at && (
                                    <span style={{ color: 'var(--success)', fontSize: 13, fontWeight: 600 }}>
                                        <LuCircleCheck size={14} style={{ display: 'inline', marginRight: 4 }} />
                                        {locale === 'ja' ? '提示済み' : 'Presented'}
                                    </span>
                                )}
                            </div>
                        )}

                        {/* Add candidate form (multi_insurer only, before compare_presented_at) */}
                        {isEditable && !run.compare_presented_at && run.comparison_scope !== 'same_insurer' && (
                            <div className="section-card">
                                <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12 }}>
                                    <LuPlus size={14} style={{ display: 'inline', marginRight: 6 }} />
                                    {i18nT(locale, 'addCandidate')}
                                </h3>
                                <div style={{ display: 'grid', gridTemplateColumns: '2fr 2fr 1fr auto', gap: 12, alignItems: 'end' }}>
                                    <div>
                                        <label className="form-label">
                                            {i18nT(locale, 'insurerName')} <span className="badge-required">{i18nT(locale, 'required')}</span>
                                        </label>
                                        <input className="form-input" value={newInsurerName} onChange={e => setNewInsurerName(e.target.value)}
                                            placeholder={locale === 'ja' ? '例: 東京海上日動' : 'e.g. Tokio Marine'} />
                                    </div>
                                    <div>
                                        <label className="form-label">{i18nT(locale, 'productName')}</label>
                                        <input className="form-input" value={newProductName} onChange={e => setNewProductName(e.target.value)}
                                            placeholder={locale === 'ja' ? '例: TAP' : 'e.g. TAP'} />
                                    </div>
                                    <div>
                                        <label className="form-label">{i18nT(locale, 'annualPremium')}</label>
                                        <input className="form-input" type="number" value={newPremium} onChange={e => setNewPremium(e.target.value)} placeholder="¥" />
                                    </div>
                                    <button className="btn-accent" onClick={handleAddCandidate} disabled={saving || !newInsurerName.trim()} style={{ height: 42 }}>
                                        <LuPlus size={16} />
                                    </button>
                                </div>
                            </div>
                        )}

                        {/* ── D-A: same_insurer 5-role layout ── */}
                        {run.comparison_scope === 'same_insurer' && (() => {
                            const ROLE_ORDER = ['prior', 'same_conditions', 'recommended_1', 'recommended_2', 'recommended_3'] as const
                            const ROLE_META: Record<string, { ja: string; en: string; color: string }> = {
                                prior:           { ja: '前年契約',   en: 'Prior Year',      color: '#6366f1' },
                                same_conditions: { ja: '前年同条件', en: 'Same Conditions',  color: '#0277bd' },
                                recommended_1:   { ja: 'おすすめ1', en: 'Recommended 1',    color: '#2e7d32' },
                                recommended_2:   { ja: 'おすすめ2', en: 'Recommended 2',    color: '#2e7d32' },
                                recommended_3:   { ja: 'おすすめ3', en: 'Recommended 3',    color: '#2e7d32' },
                            }
                            const orderedCandidates = ROLE_ORDER
                                .map(r => candidates.find(c => c.role === r))
                                .filter(Boolean) as Candidate[]
                            const recCount = candidates.filter(c => ['recommended_1','recommended_2','recommended_3'].includes(c.role ?? '')).length
                            if (orderedCandidates.length === 0) return (
                                <div className="section-card" style={{ textAlign: 'center', padding: 48 }}>
                                    <p style={{ color: 'var(--text-secondary)' }}>{i18nT(locale, 'noDataFound')}</p>
                                </div>
                            )
                            return (
                                <>
                                    <div style={{ display: 'grid', gridTemplateColumns: `repeat(${orderedCandidates.length}, 1fr)`, gap: 16 }}>
                                        {orderedCandidates.map(c => {
                                            const meta = ROLE_META[c.role ?? ''] ?? { ja: c.role ?? '', en: c.role ?? '', color: 'var(--primary)' }
                                            const isReadonly = c.role === 'prior'
                                            const canExclude = isEditable && !isReadonly && c.status === 'active' && !run.compare_presented_at
                                            return (
                                                <div key={c.id} className="section-card" style={{ borderTop: `3px solid ${meta.color}`, opacity: c.status === 'excluded' ? 0.5 : 1 }}>
                                                    <div style={{ fontSize: 11, fontWeight: 700, color: meta.color, marginBottom: 8, textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                                                        {locale === 'ja' ? meta.ja : meta.en}
                                                        {isReadonly && <span style={{ marginLeft: 6, fontWeight: 400, opacity: 0.7 }}>({locale === 'ja' ? '読取専用' : 'readonly'})</span>}
                                                    </div>
                                                    <div style={{ fontSize: 15, fontWeight: 700 }}>{c.insurer_name || '—'}</div>
                                                    {c.product_name && <div style={{ fontSize: 13, color: 'var(--text-secondary)', marginTop: 2 }}>{c.product_name}</div>}
                                                    {c.annual_premium != null && (
                                                        <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--primary)', marginTop: 8 }}>
                                                            ¥{c.annual_premium.toLocaleString()}
                                                        </div>
                                                    )}
                                                    {c.excluded_reason && (
                                                        <div style={{ fontSize: 12, color: 'var(--error)', marginTop: 8, background: 'rgba(198,40,40,0.05)', padding: '6px 10px', borderRadius: 6 }}>
                                                            {c.excluded_reason}
                                                        </div>
                                                    )}
                                                    {canExclude && (
                                                        <div style={{ marginTop: 12 }}>
                                                            {excludingId === c.id ? (
                                                                <div style={{ display: 'flex', gap: 6, flexDirection: 'column' }}>
                                                                    <input className="form-input" value={exclusionReason} onChange={e => setExclusionReason(e.target.value)}
                                                                        placeholder={locale === 'ja' ? '除外理由' : 'Exclusion reason'} />
                                                                    <div style={{ display: 'flex', gap: 6 }}>
                                                                        <button className="btn-danger" onClick={() => handleExcludeCandidate(c.id)} disabled={!exclusionReason.trim() || saving} style={{ fontSize: 12, padding: '5px 10px' }}>
                                                                            <LuCheck size={12} style={{ marginRight: 4 }} />{locale === 'ja' ? '確定' : 'Confirm'}
                                                                        </button>
                                                                        <button className="btn-secondary" onClick={() => { setExcludingId(null); setExclusionReason('') }} style={{ fontSize: 12, padding: '5px 10px' }}>
                                                                            {locale === 'ja' ? 'キャンセル' : 'Cancel'}
                                                                        </button>
                                                                    </div>
                                                                </div>
                                                            ) : (
                                                                <button onClick={() => { setExcludingId(c.id); setExclusionReason('') }} style={{
                                                                    fontSize: 12, padding: '5px 10px', border: '1px solid var(--error)', color: 'var(--error)',
                                                                    background: 'transparent', borderRadius: 6, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 4,
                                                                }}>
                                                                    <LuTrash2 size={12} /> {i18nT(locale, 'excludeCandidate')}
                                                                </button>
                                                            )}
                                                        </div>
                                                    )}
                                                </div>
                                            )
                                        })}
                                    </div>
                                    {/* Add recommended button */}
                                    {isEditable && !run.compare_presented_at && recCount < 3 && (
                                        <button className="btn-secondary" onClick={handleAddRecommended} disabled={saving}
                                            style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13 }}>
                                            <LuPlus size={14} />
                                            {locale === 'ja' ? 'おすすめを追加' : 'Add Recommended'}
                                        </button>
                                    )}
                                </>
                            )
                        })()}

                        {/* ── multi_insurer candidate columns ── */}
                        {run.comparison_scope !== 'same_insurer' && (
                            <>
                                {activeCandidates.length === 0 && (
                                    <div className="section-card" style={{ textAlign: 'center', padding: 48 }}>
                                        <p style={{ color: 'var(--text-secondary)' }}>{i18nT(locale, 'noDataFound')}</p>
                                    </div>
                                )}
                                {activeCandidates.length > 0 && (
                                    <div style={{ display: 'grid', gridTemplateColumns: `repeat(${activeCandidates.length}, 1fr)`, gap: 16 }}>
                                        {activeCandidates.map(c => (
                                            <div key={c.id} className="section-card" style={{
                                                borderTop: `3px solid ${c.role === 'current' ? '#6366f1' : c.role === 'recommended' ? 'var(--success)' : 'var(--primary)'}`,
                                                opacity: c.status === 'excluded' ? 0.5 : 1,
                                            }}>
                                                {c.role && (
                                                    <div style={{ fontSize: 11, fontWeight: 700, color: c.role === 'current' ? '#6366f1' : 'var(--success)', marginBottom: 8 }}>
                                                        {c.role === 'current' ? (locale === 'ja' ? '現在の契約' : 'Current') : (locale === 'ja' ? '推奨候補' : 'Recommended')}
                                                    </div>
                                                )}
                                                <div style={{ fontSize: 16, fontWeight: 700 }}>{c.insurer_name}</div>
                                                {c.product_name && <div style={{ fontSize: 13, color: 'var(--text-secondary)', marginTop: 2 }}>{c.product_name}</div>}
                                                {c.annual_premium != null && (
                                                    <div style={{ fontSize: 22, fontWeight: 700, color: 'var(--primary)', marginTop: 8 }}>
                                                        ¥{c.annual_premium.toLocaleString()}
                                                    </div>
                                                )}

                                                {/* M2 Spec 1: coverage_status 3-state toggle */}
                                                <div style={{ marginTop: 12 }}>
                                                    <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginBottom: 6 }}>
                                                        {locale === 'ja' ? '付帯状況' : 'Coverage Status'}
                                                    </div>
                                                    <div style={{ display: 'flex', gap: 4 }}>
                                                        {([
                                                            { value: 'full'    as CoverageStatus, ja: 'あり',   en: 'Full',    bg: '#dcfce7', color: '#166534', active: '#16a34a' },
                                                            { value: 'partial' as CoverageStatus, ja: '一部',   en: 'Partial', bg: '#fff7ed', color: '#9a3412', active: '#ea580c' },
                                                            { value: 'none'    as CoverageStatus, ja: 'なし',   en: 'None',    bg: '#f1f5f9', color: '#475569', active: '#64748b' },
                                                        ]).map(opt => {
                                                            const isActive = c.coverage_status === opt.value
                                                            return (
                                                                <button key={opt.value}
                                                                    disabled={!isEditable || updatingCoverage === c.id}
                                                                    onClick={() => handleUpdateCoverageStatus(c.id, opt.value)}
                                                                    style={{
                                                                        flex: 1, padding: '4px 0', fontSize: 11, fontWeight: isActive ? 700 : 400,
                                                                        border: `1px solid ${isActive ? opt.active : '#e2e8f0'}`,
                                                                        borderRadius: 6, cursor: isEditable ? 'pointer' : 'default',
                                                                        background: isActive ? opt.bg : 'white',
                                                                        color: isActive ? opt.color : 'var(--text-secondary)',
                                                                    }}
                                                                >
                                                                    {locale === 'ja' ? opt.ja : opt.en}
                                                                </button>
                                                            )
                                                        })}
                                                    </div>
                                                </div>

                                                {/* M2 Spec 4: vehicle_premises table */}
                                                {c.vehicle_premises && c.vehicle_premises.length > 0 && (
                                                    <div style={{ marginTop: 12 }}>
                                                        <div style={{ fontSize: 11, color: 'var(--text-secondary)', marginBottom: 6 }}>
                                                            {locale === 'ja' ? '車両別前提条件' : 'Per-Vehicle Conditions'}
                                                        </div>
                                                        <table style={{ width: '100%', fontSize: 11, borderCollapse: 'collapse' }}>
                                                            <thead>
                                                                <tr style={{ background: '#f8fafc' }}>
                                                                    <th style={{ padding: '4px 6px', textAlign: 'left', borderBottom: '1px solid #e2e8f0', fontWeight: 600 }}>
                                                                        {locale === 'ja' ? '車両' : 'Veh.'}
                                                                    </th>
                                                                    <th style={{ padding: '4px 6px', textAlign: 'left', borderBottom: '1px solid #e2e8f0', fontWeight: 600 }}>
                                                                        {locale === 'ja' ? '等級' : 'Grade'}
                                                                    </th>
                                                                    {run.customer_type === 'individual' && <>
                                                                        <th style={{ padding: '4px 6px', textAlign: 'left', borderBottom: '1px solid #e2e8f0', fontWeight: 600 }}>
                                                                            {locale === 'ja' ? '年齢条件' : 'Age Cond.'}
                                                                        </th>
                                                                        <th style={{ padding: '4px 6px', textAlign: 'left', borderBottom: '1px solid #e2e8f0', fontWeight: 600 }}>
                                                                            {locale === 'ja' ? '運転者限定' : 'Driver Limit'}
                                                                        </th>
                                                                    </>}
                                                                </tr>
                                                            </thead>
                                                            <tbody>
                                                                {c.vehicle_premises.map((vp, i) => (
                                                                    <tr key={i} style={{ borderBottom: '1px solid #f1f5f9' }}>
                                                                        <td style={{ padding: '4px 6px' }}>{String(vp.vehicle_no ?? i + 1)}</td>
                                                                        <td style={{ padding: '4px 6px' }}>{String(vp.grade ?? '—')}</td>
                                                                        {run.customer_type === 'individual' && <>
                                                                            <td style={{ padding: '4px 6px' }}>{String(vp.age_condition ?? '—')}</td>
                                                                            <td style={{ padding: '4px 6px' }}>{String(vp.driver_limit ?? '—')}</td>
                                                                        </>}
                                                                    </tr>
                                                                ))}
                                                            </tbody>
                                                        </table>
                                                    </div>
                                                )}

                                                {c.excluded_reason && (
                                                    <div style={{ fontSize: 12, color: 'var(--error)', marginTop: 8, background: 'rgba(198,40,40,0.05)', padding: '6px 10px', borderRadius: 6 }}>
                                                        {c.excluded_reason}
                                                    </div>
                                                )}
                                                {isEditable && c.status === 'active' && !run.compare_presented_at && (
                                                    <div style={{ marginTop: 12 }}>
                                                        {excludingId === c.id ? (
                                                            <div style={{ display: 'flex', gap: 6, flexDirection: 'column' }}>
                                                                <input className="form-input" value={exclusionReason} onChange={e => setExclusionReason(e.target.value)}
                                                                    placeholder={locale === 'ja' ? '除外理由' : 'Exclusion reason'} />
                                                                <div style={{ display: 'flex', gap: 6 }}>
                                                                    <button className="btn-danger" onClick={() => handleExcludeCandidate(c.id)} disabled={!exclusionReason.trim() || saving} style={{ fontSize: 12, padding: '5px 10px' }}>
                                                                        <LuCheck size={12} style={{ marginRight: 4 }} />
                                                                        {locale === 'ja' ? '確定' : 'Confirm'}
                                                                    </button>
                                                                    <button className="btn-secondary" onClick={() => { setExcludingId(null); setExclusionReason('') }} style={{ fontSize: 12, padding: '5px 10px' }}>
                                                                        {locale === 'ja' ? 'キャンセル' : 'Cancel'}
                                                                    </button>
                                                                </div>
                                                            </div>
                                                        ) : (
                                                            <button onClick={() => { setExcludingId(c.id); setExclusionReason('') }} style={{
                                                                fontSize: 12, padding: '5px 10px', border: '1px solid var(--error)', color: 'var(--error)',
                                                                background: 'transparent', borderRadius: 6, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 4,
                                                            }}>
                                                                <LuTrash2 size={12} /> {i18nT(locale, 'excludeCandidate')}
                                                            </button>
                                                        )}
                                                    </div>
                                                )}
                                            </div>
                                        ))}
                                    </div>
                                )}
                            </>
                        )}

                        {/* D-C: 重複補償判定 */}
                        {snapshot && (
                            <div className="section-card">
                                <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 12 }}>
                                    {locale === 'ja' ? '重複補償の確認' : 'Redundancy Check'}
                                </h3>
                                {redundancyDecisions.length === 0 && (
                                    <p style={{ fontSize: 13, color: 'var(--text-secondary)', marginBottom: 12 }}>
                                        {locale === 'ja' ? '重複補償項目はありません。項目を追加して判断を記録できます。' : 'No redundancy items. Add items to record decisions.'}
                                    </p>
                                )}
                                {redundancyDecisions.map((d) => (
                                    <RedundancyRow key={d.item_key} item={d} isEditable={isEditable}
                                        locale={locale} saving={savingRedundancy}
                                        onSave={handleSaveRedundancyDecision}
                                        onRemove={handleRemoveRedundancyItem} />
                                ))}
                                {isEditable && (
                                    <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                                        <input className="form-input" value={newRedundancyItem}
                                            onChange={e => setNewRedundancyItem(e.target.value)}
                                            placeholder={locale === 'ja' ? '項目名（例：人身傷害×傷害保険）' : 'Item name (e.g. Personal injury overlap)'}
                                            style={{ flex: 1 }} />
                                        <button className="btn-secondary" style={{ fontSize: 13 }}
                                            disabled={!newRedundancyItem.trim() || savingRedundancy}
                                            onClick={() => {
                                                if (!newRedundancyItem.trim()) return
                                                handleSaveRedundancyDecision(newRedundancyItem.trim(), 'keep', '')
                                                setNewRedundancyItem('')
                                            }}>
                                            {locale === 'ja' ? '追加' : 'Add'}
                                        </button>
                                    </div>
                                )}
                            </div>
                        )}
                    </div>
                )}

                {/* ═══════════════════════════════════════ */}
                {/* TAB: FINALIZE                           */}
                {/* ═══════════════════════════════════════ */}
                {activeTab === 'finalize' && (
                    <div className="animate-fade-in space-y-6">
                        {run.run_status === 'finalized' ? (
                            <div className="section-card" style={{ background: '#f0fdf4', borderColor: '#86efac' }}>
                                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                                    <LuCircleCheck size={20} color="var(--success)" />
                                    <div>
                                        <p style={{ fontWeight: 700, color: '#14532d' }}>
                                            {locale === 'ja' ? '確定済（編集不可）' : 'Confirmed (Read-only)'}
                                        </p>
                                        {run.finalized_at && (
                                            <p style={{ fontSize: 13, color: '#166534' }}>
                                                {format(new Date(run.finalized_at), 'yyyy/MM/dd HH:mm')}
                                            </p>
                                        )}
                                        {run.pdf_object_key && (
                                            <p style={{ fontSize: 12, color: '#166534', marginTop: 4, fontFamily: 'monospace' }}>
                                                {run.pdf_object_key}
                                            </p>
                                        )}
                                    </div>
                                </div>
                            </div>
                        ) : (
                            <>
                                {/* Pre-flight checklist */}
                                <div className="section-card">
                                    <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 16 }}>
                                        {i18nT(locale, 'finalizePreflightTitle')}
                                    </h3>
                                    <ul style={{ display: 'grid', gap: 10 }}>
                                        {preflightChecks.map(check => (
                                            <li key={check.id} style={{
                                                display: 'flex', alignItems: 'center', gap: 10, fontSize: 14,
                                                padding: '10px 14px', borderRadius: 8,
                                                background: check.pass ? 'rgba(46,125,50,0.06)' : 'rgba(198,40,40,0.06)',
                                            }}>
                                                {check.pass
                                                    ? <LuCircleCheck size={16} color="var(--success)" />
                                                    : <LuCircleX size={16} color="var(--error)" />}
                                                <span style={{ color: check.pass ? '#166534' : '#991b1b' }}>
                                                    {locale === 'ja' ? check.labelJa : check.labelEn}
                                                </span>
                                            </li>
                                        ))}
                                    </ul>
                                </div>

                                {/* M2 Spec 2: 課題解消メモ */}
                                <div className="section-card space-y-2">
                                    <label style={{ fontSize: 14, fontWeight: 600, display: 'block' }}>
                                        {locale === 'ja' ? '課題解消メモ（任意）' : 'Issue resolution memo (optional)'}
                                    </label>
                                    <p style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                                        {locale === 'ja'
                                            ? '当初課題の解消状況や経緯を記録します。空欄の場合は未対応扱いになります。'
                                            : 'Record how the detected issues were resolved. Left blank means unresolved.'}
                                    </p>
                                    <textarea
                                        value={resolutionMemo}
                                        onChange={e => setResolutionMemo(e.target.value)}
                                        rows={3}
                                        style={{ width: '100%', padding: '8px 10px', borderRadius: 8, border: '1px solid #e2e8f0', fontSize: 13, resize: 'vertical' }}
                                        placeholder={locale === 'ja' ? '例：特約付帯の意向を確認し、改善プランで解消' : 'e.g. Confirmed intent to add rider; resolved with improved plan'}
                                        disabled={!isEditable}
                                    />
                                    {isEditable && (
                                        <button
                                            type="button"
                                            disabled={savingMemo}
                                            onClick={async () => {
                                                if (!snapshot) return
                                                setSavingMemo(true)
                                                const supabase = createClient()
                                                await supabase.from('snapshot').update({ resolution_memo: resolutionMemo || null }).eq('id', snapshot.id)
                                                setSavingMemo(false)
                                                showToast(locale === 'ja' ? 'メモを保存しました' : 'Memo saved')
                                            }}
                                            style={{ fontSize: 13, padding: '6px 14px', borderRadius: 6, border: '1px solid #cbd5e1', background: 'white', cursor: 'pointer' }}
                                        >
                                            {savingMemo ? '...' : (locale === 'ja' ? '保存' : 'Save')}
                                        </button>
                                    )}
                                </div>

                                {/* D-B: 交付記録 */}
                                <div className="section-card space-y-3">
                                    <label style={{ fontSize: 14, fontWeight: 600, display: 'block' }}>
                                        {locale === 'ja' ? '交付記録' : 'Delivery Record'}
                                    </label>
                                    <div>
                                        <label className="form-label">{locale === 'ja' ? '交付方法' : 'Delivery Method'}</label>
                                        <select value={deliveryMethod} onChange={e => setDeliveryMethod(e.target.value)}
                                            disabled={!isEditable}
                                            style={{ width: '100%', padding: '8px 10px', borderRadius: 8, border: '1px solid #e2e8f0', fontSize: 13 }}>
                                            <option value="">{locale === 'ja' ? '選択してください' : 'Select'}</option>
                                            <option value="hand">{locale === 'ja' ? '対面交付' : 'In-person'}</option>
                                            <option value="mail">{locale === 'ja' ? '郵送' : 'Mail'}</option>
                                            <option value="email">{locale === 'ja' ? 'メール' : 'Email'}</option>
                                            <option value="digital">{locale === 'ja' ? 'デジタル交付' : 'Digital'}</option>
                                        </select>
                                    </div>
                                    <label style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: isEditable ? 'pointer' : 'default' }}>
                                        <input type="checkbox" checked={deliveryConfirmed}
                                            onChange={e => setDeliveryConfirmed(e.target.checked)}
                                            disabled={!isEditable}
                                            style={{ width: 16, height: 16 }} />
                                        <span style={{ fontSize: 13 }}>
                                            {locale === 'ja' ? '交付確認済み（お客様に書類を交付しました）' : 'Delivery confirmed (documents handed to customer)'}
                                        </span>
                                    </label>
                                    {run.delivery_confirmed_at && (
                                        <p style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                                            {locale === 'ja' ? '交付確認日時: ' : 'Confirmed at: '}
                                            {format(new Date(run.delivery_confirmed_at), 'yyyy/MM/dd HH:mm')}
                                        </p>
                                    )}
                                    {isEditable && (
                                        <button type="button" disabled={savingDelivery} onClick={handleSaveDelivery}
                                            style={{ fontSize: 13, padding: '6px 14px', borderRadius: 6, border: '1px solid #cbd5e1', background: 'white', cursor: 'pointer' }}>
                                            {savingDelivery ? '...' : (locale === 'ja' ? '保存' : 'Save')}
                                        </button>
                                    )}
                                </div>

                                {/* Consent for compare path */}
                                {run.customer_decision === 'compare' && (
                                    <div className="section-card">
                                        <label style={{ display: 'flex', alignItems: 'start', gap: 12, cursor: 'pointer' }}>
                                            <input
                                                type="checkbox"
                                                checked={consentComparisonResult}
                                                onChange={e => setConsentComparisonResult(e.target.checked)}
                                                style={{ marginTop: 2, width: 16, height: 16 }}
                                            />
                                            <span style={{ fontSize: 14 }}>{i18nT(locale, 'consentComparisonResult')}</span>
                                        </label>
                                    </div>
                                )}

                                {error && (
                                    <div style={{ background: 'rgba(198,40,40,0.08)', color: 'var(--error)', padding: '10px 14px', borderRadius: 8, fontSize: 13 }}>
                                        {error}
                                    </div>
                                )}

                                <button
                                    className="btn-primary"
                                    style={{ width: '100%', opacity: allPreflightPass ? 1 : 0.4 }}
                                    disabled={!allPreflightPass || finalizing || !isEditable}
                                    onClick={handleFinalize}
                                >
                                    <LuLock size={16} style={{ marginRight: 6 }} />
                                    {finalizing
                                        ? (locale === 'ja' ? '確定中...' : 'Finalizing...')
                                        : i18nT(locale, 'finalize')}
                                </button>

                                {!allPreflightPass && (
                                    <p style={{ fontSize: 13, color: 'var(--text-secondary)', textAlign: 'center' }}>
                                        {i18nT(locale, 'finalizeBlocked')}
                                    </p>
                                )}
                            </>
                        )}
                    </div>
                )}

                {/* ═══════════════════════════════════════ */}
                {/* TAB: AUDIT                              */}
                {/* ═══════════════════════════════════════ */}
                {activeTab === 'audit' && (
                    <div className="animate-fade-in">
                        <div style={{ background: 'white', borderRadius: 12, boxShadow: '0 1px 4px rgba(0,0,0,0.04)', overflow: 'hidden' }}>
                            {auditEvents.length === 0 ? (
                                <div style={{ padding: 48, textAlign: 'center', color: 'var(--text-secondary)' }}>
                                    <LuClock size={40} color="#ddd" />
                                    <p style={{ marginTop: 12 }}>{i18nT(locale, 'noDataFound')}</p>
                                </div>
                            ) : (
                                <table className="data-table">
                                    <thead>
                                        <tr>
                                            <th>{locale === 'ja' ? '日時' : 'Time'}</th>
                                            <th>{locale === 'ja' ? 'イベント' : 'Event'}</th>
                                            <th>{locale === 'ja' ? 'ペイロード' : 'Payload'}</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {auditEvents.map(evt => {
                                            const colors = auditEventColor(evt.event_type)
                                            return (
                                                <tr key={evt.id}>
                                                    <td style={{ fontSize: 12, color: 'var(--text-secondary)', whiteSpace: 'nowrap' }}>
                                                        {format(new Date(evt.occurred_at), 'MM/dd HH:mm:ss')}
                                                    </td>
                                                    <td>
                                                        <span style={{
                                                            fontSize: 12, padding: '2px 8px', borderRadius: 10, fontWeight: 600,
                                                            background: colors.bg, color: colors.color,
                                                        }}>
                                                            {evt.event_type}
                                                        </span>
                                                    </td>
                                                    <td style={{ fontSize: 12, color: 'var(--text-secondary)', maxWidth: 280, overflow: 'hidden', textOverflow: 'ellipsis', fontFamily: 'monospace' }}>
                                                        {evt.payload ? JSON.stringify(evt.payload) : '—'}
                                                    </td>
                                                </tr>
                                            )
                                        })}
                                    </tbody>
                                </table>
                            )}
                        </div>
                    </div>
                )}
            </div>

            {/* Toast */}
            {toast && (
                <div className={`toast toast-${toast.type}`}>{toast.msg}</div>
            )}
        </div>
    )
}
