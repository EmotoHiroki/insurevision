'use client'

import React, { useEffect, useState, useCallback } from 'react'
import { useRouter, useParams, useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import type { Run, Candidate, Operator, AuditEvent, Snapshot, CoverageStatus, ExclusionReasonCode } from '@/lib/types'
import { t as i18nT } from '@/lib/i18n'
import { format } from 'date-fns'
import {
    LuShield, LuGlobe, LuArrowLeft, LuCheck, LuPlus, LuTrash2,
    LuClock, LuUser, LuRefreshCw, LuFileText, LuChartBar, LuLock,
    LuCircleCheck, LuCircleX, LuDownload, LuTriangle,
} from 'react-icons/lu'

// ─────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────
type TabKey = 'overview' | 'comparison' | 'finalize' | 'audit' | 'documents'

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
    const [exclusionReasonCode, setExclusionReasonCode] = useState<ExclusionReasonCode | ''>('')

    // Finalize tab
    const [consentComparisonResult, setConsentComparisonResult] = useState(false)
    const [finalizing, setFinalizing] = useState(false)
    // M2 Spec 2: 課題解消メモ
    const [resolutionMemo, setResolutionMemo] = useState('')
    const [savingMemo, setSavingMemo] = useState(false)
    // M2 Spec 1: coverage_status update
    const [updatingCoverage, setUpdatingCoverage] = useState<string | null>(null)
    // A5 fix: synchronous in-flight guard (React state alone isn't checked until a re-render,
    // which is too late to stop a fast double-click / double-fire — see handleUpdateCoverageStatus)
    const updatingCoverageRef = React.useRef<string | null>(null)
    // D-B / G-10: delivery record
    const [deliveryMethod, setDeliveryMethod] = useState<string>('')
    const [deliveryConfirmed, setDeliveryConfirmed] = useState(false)
    const [deliveryReference, setDeliveryReference] = useState('')
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
    // G-21: post-record phase completion state
    const [completingPhase1, setCompletingPhase1] = useState(false)
    const [completingPhase2, setCompletingPhase2] = useState(false)
    // Phase2-a state
    const [savingConsent, setSavingConsent] = useState(false)
    const [savingSmartphone, setSavingSmartphone] = useState(false)
    const [savingPaper, setSavingPaper] = useState(false)
    const [savingImportantMatters, setSavingImportantMatters] = useState(false)
    const [importantMattersMethod, setImportantMattersMethod] = useState<'electronic' | 'paper'>('electronic')
    const [smartphoneUrl, setSmartphoneUrl] = useState('')
    const [copied, setCopied] = useState(false)
    const [lastRefreshed, setLastRefreshed] = useState<Date | null>(null)
    // Documents tab (MS3)
    const [reportData, setReportData] = useState<Record<string, unknown> | null>(null)
    const [loadingReport, setLoadingReport] = useState(false)
    const [savingPlanSelection, setSavingPlanSelection] = useState(false)
    const [recommendedId, setRecommendedId] = useState<string>('')
    const [decidedId, setDecidedId] = useState<string>('')
    const [planDiffReason, setPlanDiffReason] = useState<string>('')

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
            setDeliveryReference((runData as Run).delivery_reference ?? '')
            setRecommendedId((runData as Run).recommended_candidate_id ?? '')
            setDecidedId((runData as Run).decided_candidate_id ?? '')
            setPlanDiffReason((runData as Run).plan_diff_reason ?? '')
        }

        const { data: candData } = await supabase.from('candidate').select('*').eq('run_id', runId).order('slot_no')
        setCandidates((candData as Candidate[]) || [])

        const { data: auditData } = await supabase
            .from('audit_event').select('*').eq('run_id', runId).order('occurred_at', { ascending: true })
        setAuditEvents((auditData as AuditEvent[]) || [])

        setLastRefreshed(new Date())
        setLoading(false)
    }, [runId, router])

    useEffect(() => { loadData() }, [loadData])

    // B-1: lightweight polling when smartphone confirmation is pending
    // b1-MS1 #49 (2026-08-01): was only 'pending'/'recruiter_confirmed',
    // which incorrectly treated a customer-confirms-first run as already
    // done (polling stopped before the recruiter had confirmed). Any
    // single-sided confirmation still means "still waiting" - only
    // 'both_confirmed' (migration 041) means fully done.
    useEffect(() => {
        if (!run) return
        const isPending = run.smartphone_conf_status === 'pending' ||
            run.smartphone_conf_status === 'recruiter_confirmed' ||
            run.smartphone_conf_status === 'customer_confirmed'
        if (!isPending || run.run_status !== 'draft') return
        const interval = setInterval(() => { loadData() }, 30000)
        return () => clearInterval(interval)
    }, [run, loadData])

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
        if (!operator) return
        // G-4: R-999 requires a memo
        if (exclusionReasonCode === 'R-999' && !exclusionReason.trim()) {
            showToast(locale === 'ja' ? 'R-999選択時はメモ入力が必須です' : 'Memo is required when R-999 is selected', 'error')
            return
        }
        setSaving(true)
        try {
            const supabase = createClient()
            const { error: rpcErr } = await supabase.rpc('exclude_candidate', {
                p_candidate_id: candidateId,
                p_reason_code: exclusionReasonCode || null,
                p_reason_text: exclusionReason.trim() || null,
            })
            if (rpcErr) throw rpcErr

            setExcludingId(null)
            setExclusionReason('')
            setExclusionReasonCode('')
            await loadData()
            showToast(locale === 'ja' ? '除外しました' : 'Candidate excluded')
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSaving(false) }
    }

    const handleStartPresenting = async () => {
        if (!operator || !run) return
        if (run.compare_presented_at) return   // already presented
        const activeCount = candidates.filter(c => c.status === 'active').length
        if (activeCount === 0) {
            showToast(locale === 'ja' ? '比較プランが1件以上必要です' : 'At least one active plan is required', 'error')
            return
        }
        setSaving(true)
        try {
            const supabase = createClient()
            const { error } = await supabase.rpc('record_compare_presented', { p_run_id: runId })
            if (error) throw error
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
    // A5 fix: `disabled={updatingCoverage === c.id}` on the button only takes effect after a
    // React re-render, so a fast real double-click (or double-fire) can enter this function
    // twice before the first call's setUpdatingCoverage is ever painted. Guard synchronously
    // with a ref (checked/set before any await) so the second call returns immediately instead
    // of firing a second RPC + audit_event. Also short-circuit when the requested status
    // already matches the candidate's current status, matching the existing "re-selecting an
    // already-selected value is a no-op" expectation and avoiding a duplicate audit row.
    const handleUpdateCoverageStatus = async (candidateId: string, status: CoverageStatus) => {
        if (updatingCoverageRef.current === candidateId) return
        const current = candidates.find(c => c.id === candidateId)
        if (current && current.coverage_status === status) return

        updatingCoverageRef.current = candidateId
        setUpdatingCoverage(candidateId)
        try {
            const supabase = createClient()
            const { error: rpcErr } = await supabase.rpc('update_candidate_coverage_status', {
                p_candidate_id: candidateId,
                p_status: status,
            })
            if (!rpcErr) {
                setCandidates(prev => prev.map(c => c.id === candidateId ? { ...c, coverage_status: status } : c))
            } else {
                showToast(rpcErr.message, 'error')
            }
        } finally {
            updatingCoverageRef.current = null
            setUpdatingCoverage(null)
        }
    }

    // G-10: save delivery record
    const handleSaveDelivery = async () => {
        if (!operator) return
        setSavingDelivery(true)
        const supabase = createClient()
        const now = new Date().toISOString()
        await supabase.from('run').update({
            delivery_method: deliveryMethod || null,
            delivery_confirmed_at: deliveryConfirmed ? now : null,
            delivery_status: deliveryConfirmed ? 'delivered' : 'not_delivered',
            delivery_reference: deliveryReference.trim() || null,
        }).eq('id', runId)
        if (deliveryConfirmed) {
            await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: 'delivery_recorded' as const,
                operator_id: operator.id,
                payload: { delivery_method: deliveryMethod, confirmed_at: now, delivery_reference: deliveryReference.trim() || null },
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
        // b1-MS1 #40横展開: snapshotの直接updateは権限剥奪により失敗するため、
        // agency照合・確定後凍結を行うRPC経由に変更（migration 032）。
        await supabase.rpc('update_snapshot_redundancy_decisions', {
            p_snapshot_id: snapshot.id,
            p_redundancy_decisions: updated,
        })
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
        await supabase.rpc('update_snapshot_redundancy_decisions', {
            p_snapshot_id: snapshot.id,
            p_redundancy_decisions: updated,
        })
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
    // G-21: 事後記録フェーズ1完了
    // ─────────────────────────────────────────────
    const handleCompletePhase1 = async () => {
        if (!operator || !run) return
        if (!run.compare_presented_at) {
            showToast(locale === 'ja' ? '比較提示が未完了です' : 'Comparison must be presented first', 'error')
            return
        }
        setCompletingPhase1(true)
        try {
            const supabase = createClient()
            const now = new Date().toISOString()
            const { error: upErr } = await supabase.from('run').update({
                run_status: 'post_record_pending',
                post_record_status: 'phase1_done',
                post_record_phase1_at: now,
            }).eq('id', runId)
            if (upErr) throw upErr
            await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: 'post_record_phase1_completed' as const,
                operator_id: operator.id,
                payload: { phase1_at: now },
            })
            showToast(locale === 'ja' ? 'フェーズ1を完了しました' : 'Phase 1 completed')
            await loadData()
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setCompletingPhase1(false) }
    }

    // ─────────────────────────────────────────────
    // G-21: 事後記録フェーズ2完了
    // ─────────────────────────────────────────────
    const handleCompletePhase2 = async () => {
        if (!operator || !run) return
        setCompletingPhase2(true)
        try {
            const supabase = createClient()
            const now = new Date().toISOString()
            const { error: upErr } = await supabase.from('run').update({
                post_record_status: 'phase2_done',
                post_record_phase2_at: now,
            }).eq('id', runId)
            if (upErr) throw upErr
            await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: 'post_record_phase2_completed' as const,
                operator_id: operator.id,
                payload: { phase2_at: now },
            })
            showToast(locale === 'ja' ? 'フェーズ2を完了しました' : 'Phase 2 completed')
            await loadData()
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setCompletingPhase2(false) }
    }

    // ─────────────────────────────────────────────
    // Phase2-a: G-27 電子同意確認
    // ─────────────────────────────────────────────
    const handleRecordConsent = async (status: 'agreed' | 'declined' | 'face_confirmed') => {
        if (!operator) return
        setSavingConsent(true)
        try {
            const res = await fetch(`/api/run/${runId}/consent`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ operatorId: operator.id, status }),
            })
            if (!res.ok) throw new Error((await res.json()).error)
            showToast(locale === 'ja' ? '同意ステータスを記録しました' : 'Consent status recorded')
            await loadData()
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSavingConsent(false) }
    }

    // ─────────────────────────────────────────────
    // Phase2-a: スマホ確認リンク発行
    // ─────────────────────────────────────────────
    const handleGenerateSmartphoneUrl = async (role: 'recruiter' | 'customer') => {
        try {
            const res = await fetch(`/api/run/${runId}/smartphone-token`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ role }),
            })
            if (!res.ok) throw new Error((await res.json()).error)
            const data = await res.json() as { url: string }
            setSmartphoneUrl(data.url)
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        }
    }

    const handleCopyUrl = async () => {
        if (!smartphoneUrl) return
        await navigator.clipboard.writeText(smartphoneUrl)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
    }

    const handleRecordSmartphone = async (role: 'recruiter' | 'customer') => {
        if (!operator) return
        setSavingSmartphone(true)
        try {
            const res = await fetch(`/api/run/${runId}/smartphone-confirm`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ role }),
            })
            if (!res.ok) throw new Error((await res.json()).error)
            showToast(locale === 'ja' ? 'スマホ確認を記録しました' : 'Smartphone confirmation recorded')
            await loadData()
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSavingSmartphone(false) }
    }

    // ─────────────────────────────────────────────
    // Phase2-a: 紙面確認完了
    // ─────────────────────────────────────────────
    const handlePaperConfirm = async () => {
        if (!operator) return
        setSavingPaper(true)
        try {
            const res = await fetch(`/api/run/${runId}/paper-confirm`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ operatorId: operator.id }),
            })
            if (!res.ok) throw new Error((await res.json()).error)
            showToast(locale === 'ja' ? '紙面確認を完了しました' : 'Paper confirmation completed')
            await loadData()
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSavingPaper(false) }
    }

    // ─────────────────────────────────────────────
    // Phase2-a: 重要事項説明書交付確認
    // ─────────────────────────────────────────────
    const handleImportantMattersDelivery = async () => {
        if (!operator) return
        setSavingImportantMatters(true)
        try {
            const res = await fetch(`/api/run/${runId}/important-matters`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ operatorId: operator.id, deliveryMethod: importantMattersMethod }),
            })
            if (!res.ok) throw new Error((await res.json()).error)
            showToast(locale === 'ja' ? '重要事項説明書の交付を記録しました' : 'Important matters delivery recorded')
            await loadData()
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSavingImportantMatters(false) }
    }

    // ─────────────────────────────────────────────
    // MS3: 書面タブ
    // ─────────────────────────────────────────────
    const loadReportData = async () => {
        setLoadingReport(true)
        try {
            const res = await fetch(`/api/run/${runId}/report-data`)
            if (res.ok) setReportData(await res.json())
        } finally { setLoadingReport(false) }
    }

    const handleSavePlanSelection = async () => {
        if (!operator) return
        setSavingPlanSelection(true)
        try {
            const res = await fetch(`/api/run/${runId}/plan-selection`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    operatorId: operator.id,
                    recommendedCandidateId: recommendedId || null,
                    decidedCandidateId: decidedId || null,
                    planDiffReason: planDiffReason.trim() || null,
                }),
            })
            if (!res.ok) throw new Error((await res.json()).error)
            showToast(locale === 'ja' ? 'プラン選択を保存しました' : 'Plan selection saved')
            await loadData()
            await loadReportData()
        } catch (e: unknown) {
            showToast(e instanceof Error ? e.message : 'Error', 'error')
        } finally { setSavingPlanSelection(false) }
    }

    const handleDownloadCsv = () => {
        window.open(`/api/run/${runId}/csv-export`, '_blank')
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
        // Phase2-a: important_matters_delivered gate (only when meeting_scene is set)
        ...(run.meeting_scene ? [{
            id: 'important_matters_delivered',
            labelJa: '重要事項説明書の交付確認が完了している（Phase2-a）',
            labelEn: 'Important matters delivery confirmed (Phase2-a)',
            pass: run.important_matters_delivered,
        }] : []),
        // Phase2-a: electronic consent must be recorded when scene requires it
        ...((['visit_smartphone', 'pc_tablet', 'web_meeting'] as const).includes(run.meeting_scene as 'visit_smartphone' | 'pc_tablet' | 'web_meeting') ? [{
            id: 'electronic_consent_recorded',
            labelJa: '電子同意確認が記録されている（Phase2-a）',
            labelEn: 'Electronic consent recorded (Phase2-a)',
            pass: !!run.electronic_consent_status && run.electronic_consent_status !== 'not_recorded',
        }] : []),
        // Phase2-a: smartphone confirmation complete for visit_smartphone
        ...(run.meeting_scene === 'visit_smartphone' && run.electronic_consent_status !== 'declined' ? [{
            id: 'customer_smartphone_confirmed',
            labelJa: 'お客様スマホ確認が完了している（Phase2-a）',
            labelEn: 'Customer smartphone confirmation complete (Phase2-a)',
            pass: !!run.customer_smartphone_confirmed_at,
        }] : []),
        // MS3: D-4 plan selection recorded when comparison done
        ...(run.compare_presented_at ? [{
            id: 'decided_plan_set',
            labelJa: 'お客様決定プランが設定されている（MS3）',
            labelEn: 'Customer decided plan set (MS3)',
            pass: !!run.decided_candidate_id,
        }] : []),
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
            post_record_pending: { ja: '事後記録待ち', en: 'Post-Record Pending' },
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

    // G-21: post_record_pending is also editable (for phase 2 input like resolution memo + consents)
    const isEditable = run.run_status === 'draft' || run.run_status === 'post_record_pending'
    const activeCandidates = candidates.filter(c => c.status === 'active')

    const TABS: Array<{ key: TabKey; labelJa: string; labelEn: string; icon: React.ElementType }> = [
        { key: 'overview', labelJa: '概要', labelEn: 'Overview', icon: LuUser },
        { key: 'comparison', labelJa: '比較', labelEn: 'Comparison', icon: LuChartBar },
        { key: 'finalize', labelJa: '確定', labelEn: 'Finalize', icon: LuLock },
        { key: 'audit', labelJa: '監査ログ', labelEn: 'Audit', icon: LuClock },
        { key: 'documents', labelJa: '書面・証跡', labelEn: 'Documents', icon: LuFileText },
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
                    <button onClick={loadData} title={lastRefreshed ? `最終更新: ${lastRefreshed.toLocaleTimeString()}` : '更新'} style={{
                        background: 'rgba(255,255,255,0.1)', border: 'none', color: 'white',
                        padding: '6px 10px', borderRadius: 6, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 4,
                    }}>
                        <LuRefreshCw size={16} />
                        {lastRefreshed && (
                            <span style={{ fontSize: 10, opacity: 0.7 }}>{lastRefreshed.toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' })}</span>
                        )}
                    </button>
                </div>
            </header>

            <div style={{ maxWidth: 1280, margin: '0 auto', padding: 28 }}>
                {/* Tabs */}
                <div className="m3-tab-bar" style={{
                    display: 'flex', gap: 4, marginBottom: 24, background: 'white',
                    borderRadius: 10, padding: 4, boxShadow: '0 1px 3px rgba(0,0,0,0.04)',
                }}>
                    {TABS.map(tab => (
                        <button
                            key={tab.key}
                            onClick={() => setActiveTab(tab.key)}
                            className="m3-tab-btn"
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
                    <div className="animate-fade-in m3-two-col-grid" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
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
                                {run.recording_mode && (
                                    <div>
                                        <dt className="form-label">{locale === 'ja' ? '記録方式' : 'Recording Mode'}</dt>
                                        <dd>{run.recording_mode === 'realtime'
                                            ? (locale === 'ja' ? 'リアルタイム記録' : 'Real-time')
                                            : (locale === 'ja' ? '事後記録' : 'Post-record')}</dd>
                                    </div>
                                )}
                                {run.input_device && (
                                    <div>
                                        <dt className="form-label">{locale === 'ja' ? '入力デバイス' : 'Input Device'}</dt>
                                        <dd>{{
                                            tablet_pc: locale === 'ja' ? 'タブレット/PC' : 'Tablet/PC',
                                            customer_smartphone: locale === 'ja' ? 'お客様スマートフォン' : 'Customer Smartphone',
                                            agent_smartphone: locale === 'ja' ? '募集人スマートフォン' : 'Agent Smartphone',
                                        }[run.input_device] ?? run.input_device}</dd>
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

                        {/* ─ Phase2-a panels (only when meeting_scene is set) ─ */}
                        {run.meeting_scene && (
                            <>
                                {/* G-28: 面談シーン */}
                                <div className="section-card" style={{ gridColumn: '1 / -1' }}>
                                    <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12, color: '#1d4ed8' }}>
                                        G-28 {locale === 'ja' ? '面談シーン' : 'Meeting Scene'}
                                    </h3>
                                    <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                                        <span style={{ background: '#eff6ff', color: '#1d4ed8', padding: '4px 12px', borderRadius: 20, fontSize: 13, fontWeight: 600 }}>
                                            {{ visit_smartphone: locale === 'ja' ? '訪問・スマホ連携' : 'Visit + Smartphone',
                                               visit_paper: locale === 'ja' ? '訪問・ペーパー確認' : 'Visit + Paper',
                                               pc_tablet: locale === 'ja' ? 'PC・タブレット型' : 'PC/Tablet',
                                               telephone: locale === 'ja' ? '電話募集型' : 'Telephone',
                                               web_meeting: locale === 'ja' ? 'WEB面談' : 'Web Meeting' }[run.meeting_scene] ?? run.meeting_scene}
                                        </span>
                                    </div>
                                </div>

                                {/* G-27: 電子的方法による提供への同意確認 */}
                                {(['visit_smartphone', 'pc_tablet', 'web_meeting'] as const).includes(run.meeting_scene as 'visit_smartphone' | 'pc_tablet' | 'web_meeting') && (
                                    <div className="section-card" style={{ gridColumn: '1 / -1' }}>
                                        <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 12, color: '#1d4ed8' }}>
                                            G-27 {locale === 'ja' ? '電子的方法による提供への同意確認' : 'Electronic Delivery Consent'}
                                        </h3>
                                        <div style={{ marginBottom: 12 }}>
                                            <span style={{ fontSize: 13, color: '#6b7280' }}>
                                                {locale === 'ja' ? '現在のステータス: ' : 'Current status: '}
                                            </span>
                                            <span style={{ fontWeight: 600, fontSize: 13, color: run.electronic_consent_status === 'agreed' ? '#16a34a' : run.electronic_consent_status === 'declined' ? '#dc2626' : '#92400e' }}>
                                                {{ agreed: locale === 'ja' ? '同意あり' : 'Agreed',
                                                   declined: locale === 'ja' ? '同意なし（紙面確認へ）' : 'Declined (paper mode)',
                                                   face_confirmed: locale === 'ja' ? '面談時確認済み' : 'Face confirmed',
                                                   not_recorded: locale === 'ja' ? '未記録' : 'Not recorded' }[run.electronic_consent_status ?? 'not_recorded'] ?? (locale === 'ja' ? '未記録' : 'Not recorded')}
                                            </span>
                                        </div>
                                        {isEditable && !run.electronic_consent_status && (
                                            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                                                <button
                                                    onClick={() => handleRecordConsent('agreed')}
                                                    disabled={savingConsent}
                                                    style={{ padding: '8px 16px', background: '#16a34a', color: 'white', border: 'none', borderRadius: 6, fontSize: 13, cursor: 'pointer', fontWeight: 600 }}
                                                >
                                                    {locale === 'ja' ? '同意あり' : 'Agreed'}
                                                </button>
                                                <button
                                                    onClick={() => handleRecordConsent('declined')}
                                                    disabled={savingConsent}
                                                    style={{ padding: '8px 16px', background: '#dc2626', color: 'white', border: 'none', borderRadius: 6, fontSize: 13, cursor: 'pointer', fontWeight: 600 }}
                                                >
                                                    {locale === 'ja' ? '同意なし（紙面確認へ）' : 'Declined (→ Paper)'}
                                                </button>
                                                <button
                                                    onClick={() => handleRecordConsent('face_confirmed')}
                                                    disabled={savingConsent}
                                                    style={{ padding: '8px 16px', background: '#d97706', color: 'white', border: 'none', borderRadius: 6, fontSize: 13, cursor: 'pointer', fontWeight: 600 }}
                                                >
                                                    {locale === 'ja' ? '面談時確認' : 'Face Confirmed'}
                                                </button>
                                            </div>
                                        )}
                                        {run.electronic_consent_confirmed_at && (
                                            <p style={{ fontSize: 12, color: '#6b7280', marginTop: 8 }}>
                                                {locale === 'ja' ? '記録日時: ' : 'Recorded: '}
                                                {new Date(run.electronic_consent_confirmed_at).toLocaleString()}
                                            </p>
                                        )}
                                    </div>
                                )}

                                {/* スマホ確認導線 (visit_smartphone のみ) */}
                                {run.meeting_scene === 'visit_smartphone' && run.electronic_consent_status !== 'declined' && (
                                    <div className="section-card" style={{ gridColumn: '1 / -1' }}>
                                        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
                                            <h3 style={{ fontSize: 15, fontWeight: 600, color: '#1d4ed8' }}>
                                                {locale === 'ja' ? 'スマホ確認導線' : 'Smartphone Confirmation'}
                                            </h3>
                                            {(run.smartphone_conf_status === 'pending' || run.smartphone_conf_status === 'recruiter_confirmed' || run.smartphone_conf_status === 'customer_confirmed') && (
                                                <span style={{ fontSize: 11, color: '#6b7280', display: 'flex', alignItems: 'center', gap: 4 }}>
                                                    <LuRefreshCw size={11} className="animate-pulse-soft" />
                                                    {locale === 'ja' ? '30秒ごとに自動更新' : 'Auto-refreshing every 30s'}
                                                </span>
                                            )}
                                        </div>
                                        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                                            <div style={{ background: run.recruiter_smartphone_confirmed_at ? '#f0fdf4' : '#f9fafb', borderRadius: 8, padding: 14, border: '1px solid #e5e7eb' }}>
                                                <p style={{ fontWeight: 600, fontSize: 13, marginBottom: 6 }}>
                                                    {locale === 'ja' ? '① 募集人確認' : '① Recruiter Confirm'}
                                                </p>
                                                {run.recruiter_smartphone_confirmed_at ? (
                                                    <p style={{ color: '#16a34a', fontSize: 12 }}>✓ {new Date(run.recruiter_smartphone_confirmed_at).toLocaleString()}</p>
                                                ) : (
                                                    isEditable && (
                                                        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                                                            <button onClick={() => handleGenerateSmartphoneUrl('recruiter')}
                                                                style={{ padding: '6px 12px', background: '#eff6ff', color: '#1d4ed8', border: '1px solid #bfdbfe', borderRadius: 6, fontSize: 12, cursor: 'pointer' }}>
                                                                {locale === 'ja' ? 'リンク発行' : 'Generate Link'}
                                                            </button>
                                                            <button onClick={() => handleRecordSmartphone('recruiter')} disabled={savingSmartphone}
                                                                style={{ padding: '6px 12px', background: '#1d4ed8', color: 'white', border: 'none', borderRadius: 6, fontSize: 12, cursor: 'pointer' }}>
                                                                {locale === 'ja' ? '確認済みとして記録' : 'Mark Confirmed'}
                                                            </button>
                                                        </div>
                                                    )
                                                )}
                                            </div>
                                            <div style={{ background: run.customer_smartphone_confirmed_at ? '#f0fdf4' : '#f9fafb', borderRadius: 8, padding: 14, border: '1px solid #e5e7eb' }}>
                                                <p style={{ fontWeight: 600, fontSize: 13, marginBottom: 6 }}>
                                                    {locale === 'ja' ? '② お客様確認' : '② Customer Confirm'}
                                                </p>
                                                {run.customer_smartphone_confirmed_at ? (
                                                    <p style={{ color: '#16a34a', fontSize: 12 }}>✓ {new Date(run.customer_smartphone_confirmed_at).toLocaleString()}</p>
                                                ) : (
                                                    isEditable && (
                                                        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                                                            <button onClick={() => handleGenerateSmartphoneUrl('customer')}
                                                                style={{ padding: '6px 12px', background: '#eff6ff', color: '#1d4ed8', border: '1px solid #bfdbfe', borderRadius: 6, fontSize: 12, cursor: 'pointer' }}>
                                                                {locale === 'ja' ? 'リンク発行' : 'Generate Link'}
                                                            </button>
                                                            <button onClick={() => handleRecordSmartphone('customer')} disabled={savingSmartphone}
                                                                style={{ padding: '6px 12px', background: '#1d4ed8', color: 'white', border: 'none', borderRadius: 6, fontSize: 12, cursor: 'pointer' }}>
                                                                {locale === 'ja' ? '確認済みとして記録' : 'Mark Confirmed'}
                                                            </button>
                                                        </div>
                                                    )
                                                )}
                                            </div>
                                        </div>
                                        {smartphoneUrl && (
                                            <div style={{ marginTop: 12, background: '#f9fafb', borderRadius: 8, padding: 12, border: '1px solid #e5e7eb' }}>
                                                <p style={{ fontSize: 11, color: '#6b7280', marginBottom: 6 }}>
                                                    {locale === 'ja' ? '確認URL（コピーしてお客様/募集人のスマホに送信）:' : 'Confirmation URL (copy and send to smartphone):'}
                                                </p>
                                                <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                                                    <code style={{ flex: 1, fontSize: 11, wordBreak: 'break-all', color: '#1d4ed8' }}>{smartphoneUrl}</code>
                                                    <button onClick={handleCopyUrl}
                                                        style={{ padding: '4px 10px', background: copied ? '#16a34a' : '#e5e7eb', color: copied ? 'white' : '#374151', border: 'none', borderRadius: 4, fontSize: 11, cursor: 'pointer', whiteSpace: 'nowrap' }}>
                                                        {copied ? (locale === 'ja' ? 'コピー済' : 'Copied!') : (locale === 'ja' ? 'コピー' : 'Copy')}
                                                    </button>
                                                </div>
                                            </div>
                                        )}
                                    </div>
                                )}

                                {/* 紙面確認モード (declined or visit_paper / telephone) */}
                                {(run.paper_confirmation_status === 'pending' ||
                                  run.meeting_scene === 'visit_paper' ||
                                  run.meeting_scene === 'telephone') && (
                                    <div className="section-card" style={{ gridColumn: '1 / -1', borderColor: run.paper_confirmation_status === 'completed' ? '#86efac' : '#fbbf24', background: run.paper_confirmation_status === 'completed' ? '#f0fdf4' : '#fffbeb' }}>
                                        <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 8, color: run.paper_confirmation_status === 'completed' ? '#15803d' : '#92400e' }}>
                                            {locale === 'ja' ? '紙面確認モード' : 'Paper Confirmation Mode'}
                                        </h3>
                                        <p style={{ fontSize: 13, color: '#78716c', marginBottom: 10 }}>
                                            {locale === 'ja'
                                                ? '募集人が紙面で内容を確認・記入します。'
                                                : 'Recruiter confirms and fills in on paper.'}
                                        </p>
                                        {run.paper_confirmation_status === 'completed' ? (
                                            <p style={{ color: '#15803d', fontWeight: 600, fontSize: 13 }}>
                                                ✓ {locale === 'ja' ? '紙面確認完了' : 'Paper confirmation complete'}
                                                {run.paper_confirmation_completed_at && ` — ${new Date(run.paper_confirmation_completed_at).toLocaleString()}`}
                                            </p>
                                        ) : (
                                            isEditable && (
                                                <button onClick={handlePaperConfirm} disabled={savingPaper}
                                                    style={{ padding: '8px 16px', background: '#d97706', color: 'white', border: 'none', borderRadius: 6, fontSize: 13, cursor: 'pointer', fontWeight: 600 }}>
                                                    {savingPaper ? '...' : (locale === 'ja' ? '紙面確認完了として記録' : 'Mark Paper Confirmation Complete')}
                                                </button>
                                            )
                                        )}
                                    </div>
                                )}

                                {/* 重要事項説明書交付確認 */}
                                <div className="section-card" style={{ gridColumn: '1 / -1', borderColor: run.important_matters_delivered ? '#86efac' : '#fca5a5', background: run.important_matters_delivered ? '#f0fdf4' : '#fef2f2' }}>
                                    <h3 style={{ fontSize: 15, fontWeight: 600, marginBottom: 8, color: run.important_matters_delivered ? '#15803d' : '#991b1b' }}>
                                        {locale === 'ja' ? '重要事項説明書 交付確認（Fail-Closed）' : 'Important Matters Delivery (Fail-Closed)'}
                                    </h3>
                                    {run.important_matters_delivered ? (
                                        <div>
                                            <p style={{ color: '#15803d', fontWeight: 600, fontSize: 13 }}>
                                                ✓ {locale === 'ja' ? '交付確認済み' : 'Delivery confirmed'}
                                            </p>
                                            <p style={{ fontSize: 12, color: '#6b7280', marginTop: 4 }}>
                                                {locale === 'ja' ? '方法: ' : 'Method: '}
                                                {run.important_matters_delivery_method === 'electronic'
                                                    ? (locale === 'ja' ? '電子交付' : 'Electronic')
                                                    : (locale === 'ja' ? '紙面交付' : 'Paper')}
                                                {run.important_matters_delivered_at && ` — ${new Date(run.important_matters_delivered_at).toLocaleString()}`}
                                            </p>
                                        </div>
                                    ) : (
                                        isEditable && (
                                            <div>
                                                <p style={{ fontSize: 13, color: '#7f1d1d', marginBottom: 10 }}>
                                                    {locale === 'ja'
                                                        ? '重要事項説明書を交付するまで確定できません。'
                                                        : 'Cannot finalize until important matters are delivered.'}
                                                </p>
                                                <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
                                                    {(['electronic', 'paper'] as const).map(m => (
                                                        <label key={m} style={{ display: 'flex', alignItems: 'center', gap: 6, cursor: 'pointer', fontSize: 13 }}>
                                                            <input type="radio" name="imMethod" value={m}
                                                                checked={importantMattersMethod === m}
                                                                onChange={() => setImportantMattersMethod(m)} />
                                                            {m === 'electronic'
                                                                ? (locale === 'ja' ? '電子交付' : 'Electronic')
                                                                : (locale === 'ja' ? '紙面交付' : 'Paper')}
                                                        </label>
                                                    ))}
                                                </div>
                                                <button onClick={handleImportantMattersDelivery} disabled={savingImportantMatters}
                                                    style={{ padding: '8px 16px', background: '#dc2626', color: 'white', border: 'none', borderRadius: 6, fontSize: 13, cursor: 'pointer', fontWeight: 600 }}>
                                                    {savingImportantMatters ? '...' : (locale === 'ja' ? '交付確認を記録する' : 'Record Delivery')}
                                                </button>
                                            </div>
                                        )
                                    )}
                                </div>
                            </>
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
                                    <div className="m3-candidate-grid" style={{ display: 'grid', gridTemplateColumns: `repeat(${orderedCandidates.length}, 1fr)`, gap: 16 }}>
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
                                                                    <select className="form-select" value={exclusionReasonCode}
                                                                        onChange={e => setExclusionReasonCode(e.target.value as ExclusionReasonCode | '')}
                                                                        style={{ fontSize: 12, padding: '5px 8px' }}>
                                                                        <option value="">{locale === 'ja' ? '除外理由コードを選択' : 'Select reason code'}</option>
                                                                        <option value="R-001">R-001: {locale === 'ja' ? '保険料が予算を超過' : 'Premium exceeds budget'}</option>
                                                                        <option value="R-002">R-002: {locale === 'ja' ? '補償内容が要件を満たさない' : 'Coverage insufficient'}</option>
                                                                        <option value="R-003">R-003: {locale === 'ja' ? '代理店の取扱い対象外' : 'Not handled by agency'}</option>
                                                                        <option value="R-004">R-004: {locale === 'ja' ? '顧客の希望により除外' : 'Excluded per customer request'}</option>
                                                                        <option value="R-005">R-005: {locale === 'ja' ? '保険会社の引受条件により除外' : 'Insurer underwriting conditions'}</option>
                                                                        <option value="R-999">R-999: {locale === 'ja' ? 'その他（メモ必須）' : 'Other (memo required)'}</option>
                                                                    </select>
                                                                    <input className="form-input" value={exclusionReason} onChange={e => setExclusionReason(e.target.value)}
                                                                        placeholder={exclusionReasonCode === 'R-999'
                                                                            ? (locale === 'ja' ? '補足メモ（必須）' : 'Memo (required)')
                                                                            : (locale === 'ja' ? '補足メモ（任意）' : 'Memo (optional)')}
                                                                        style={{ fontSize: 12 }} />
                                                                    <div style={{ display: 'flex', gap: 6 }}>
                                                                        <button className="btn-danger" onClick={() => handleExcludeCandidate(c.id)}
                                                                            disabled={saving} style={{ fontSize: 12, padding: '5px 10px' }}>
                                                                            <LuCheck size={12} style={{ marginRight: 4 }} />{locale === 'ja' ? '確定' : 'Confirm'}
                                                                        </button>
                                                                        <button className="btn-secondary" onClick={() => { setExcludingId(null); setExclusionReason(''); setExclusionReasonCode('') }} style={{ fontSize: 12, padding: '5px 10px' }}>
                                                                            {locale === 'ja' ? 'キャンセル' : 'Cancel'}
                                                                        </button>
                                                                    </div>
                                                                </div>
                                                            ) : (
                                                                <button onClick={() => { setExcludingId(c.id); setExclusionReason(''); setExclusionReasonCode('') }} style={{
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
                                    <div className="m3-candidate-grid" style={{ display: 'grid', gridTemplateColumns: `repeat(${activeCandidates.length}, 1fr)`, gap: 16 }}>
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

                                                {(c.exclusion_reason_code || c.excluded_reason) && (
                                                    <div style={{ fontSize: 12, color: 'var(--error)', marginTop: 8, background: 'rgba(198,40,40,0.05)', padding: '6px 10px', borderRadius: 6 }}>
                                                        {c.exclusion_reason_code && (
                                                            <span style={{ fontWeight: 700, marginRight: 6 }}>{c.exclusion_reason_code}</span>
                                                        )}
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
                        {/* G-21: Phase 1 summary banner — shown when post_record_pending */}
                        {run.run_status === 'post_record_pending' && run.post_record_phase1_at && (() => {
                            const phase1Date = new Date(run.post_record_phase1_at)
                            const deadline = new Date(phase1Date.getTime() + 7 * 24 * 60 * 60 * 1000)
                            const now = new Date()
                            const overdue = now > deadline && run.post_record_status !== 'phase2_done'
                            const phase2Done = run.post_record_status === 'phase2_done'
                            return (
                                <div className="section-card" style={{
                                    background: overdue ? '#fef2f2' : (phase2Done ? '#f0fdf4' : '#fffbeb'),
                                    borderColor: overdue ? '#fca5a5' : (phase2Done ? '#86efac' : '#fcd34d'),
                                }}>
                                    <div style={{ display: 'flex', alignItems: 'start', gap: 12 }}>
                                        <LuClock size={20} color={overdue ? 'var(--error)' : (phase2Done ? 'var(--success)' : '#b45309')} />
                                        <div style={{ flex: 1 }}>
                                            <p style={{ fontWeight: 700, marginBottom: 4, color: overdue ? '#991b1b' : (phase2Done ? '#14532d' : '#78350f') }}>
                                                {phase2Done
                                                    ? (locale === 'ja' ? '事後記録フェーズ2完了 — Finalize可能' : 'Post-record Phase 2 complete — ready to finalize')
                                                    : (locale === 'ja' ? '事後記録待ち — フェーズ2入力が必要です' : 'Post-record pending — Phase 2 input required')}
                                            </p>
                                            <p style={{ fontSize: 13, color: phase2Done ? '#166534' : '#78350f' }}>
                                                {locale === 'ja' ? 'フェーズ1完了日時: ' : 'Phase 1 completed: '}
                                                {format(phase1Date, 'yyyy/MM/dd HH:mm')}
                                            </p>
                                            <p style={{ fontSize: 13, color: overdue ? '#991b1b' : '#78350f', fontWeight: overdue ? 700 : 400 }}>
                                                {locale === 'ja' ? '後日入力期限: ' : 'Phase 2 deadline: '}
                                                {format(deadline, 'yyyy/MM/dd HH:mm')}
                                                {overdue && (locale === 'ja' ? '（期限超過）' : ' (overdue)')}
                                            </p>
                                            {run.post_record_phase2_at && (
                                                <p style={{ fontSize: 13, color: '#166534' }}>
                                                    {locale === 'ja' ? 'フェーズ2完了日時: ' : 'Phase 2 completed: '}
                                                    {format(new Date(run.post_record_phase2_at), 'yyyy/MM/dd HH:mm')}
                                                </p>
                                            )}
                                        </div>
                                    </div>
                                </div>
                            )
                        })()}

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
                                                await supabase.rpc('update_snapshot_resolution_memo', {
                                                    p_snapshot_id: snapshot.id,
                                                    p_resolution_memo: resolutionMemo || null,
                                                })
                                                setSavingMemo(false)
                                                showToast(locale === 'ja' ? 'メモを保存しました' : 'Memo saved')
                                            }}
                                            style={{ fontSize: 13, padding: '6px 14px', borderRadius: 6, border: '1px solid #cbd5e1', background: 'white', cursor: 'pointer' }}
                                        >
                                            {savingMemo ? '...' : (locale === 'ja' ? '保存' : 'Save')}
                                        </button>
                                    )}
                                </div>

                                {/* G-10: 交付記録（draft時は確定前入力、finalized後も更新可）*/}

                                {/* Consent for compare path */}
                                {run.customer_decision === 'compare' && (
                                    <div className="section-card">
                                        {run.input_device === 'agent_smartphone' && (
                                            <p style={{ fontSize: 12, color: '#92400e', background: '#fffbeb', padding: '6px 10px', borderRadius: 6, marginBottom: 10 }}>
                                                {locale === 'ja' ? '※ 募集人スマートフォンモード：募集人が代行確認します' : '※ Agent smartphone mode: agent confirms on behalf of customer'}
                                            </p>
                                        )}
                                        <label style={{ display: 'flex', alignItems: 'start', gap: 12, cursor: 'pointer' }}>
                                            <input
                                                type="checkbox"
                                                checked={consentComparisonResult}
                                                onChange={e => setConsentComparisonResult(e.target.checked)}
                                                style={{ marginTop: 2, width: 16, height: 16 }}
                                            />
                                            <span style={{ fontSize: 14 }}>
                                                {run.input_device === 'agent_smartphone'
                                                    ? (locale === 'ja' ? '比較結果を説明しました（募集人代行確認）' : 'Comparison result explained (agent confirmation)')
                                                    : i18nT(locale, 'consentComparisonResult')}
                                            </span>
                                        </label>
                                    </div>
                                )}

                                {error && (
                                    <div style={{ background: 'rgba(198,40,40,0.08)', color: 'var(--error)', padding: '10px 14px', borderRadius: 8, fontSize: 13 }}>
                                        {error}
                                    </div>
                                )}

                                {/* G-21: Phase-aware action button */}
                                {run.recording_mode === 'post_record' && run.run_status === 'draft' && run.customer_decision === 'compare' ? (
                                    // post_record mode, phase 1 not yet completed → show Phase 1 button
                                    <>
                                        <button
                                            className="btn-primary"
                                            style={{ width: '100%', background: '#b45309', opacity: run.compare_presented_at ? 1 : 0.4 }}
                                            disabled={!run.compare_presented_at || completingPhase1}
                                            onClick={handleCompletePhase1}
                                        >
                                            <LuClock size={16} style={{ marginRight: 6 }} />
                                            {completingPhase1
                                                ? (locale === 'ja' ? 'フェーズ1完了中...' : 'Completing Phase 1...')
                                                : (locale === 'ja' ? 'フェーズ1完了（面談終了）' : 'Complete Phase 1 (end meeting)')}
                                        </button>
                                        {!run.compare_presented_at && (
                                            <p style={{ fontSize: 13, color: 'var(--text-secondary)', textAlign: 'center' }}>
                                                {locale === 'ja' ? '比較提示の完了後にフェーズ1を完了できます' : 'Phase 1 can be completed after comparison is presented'}
                                            </p>
                                        )}
                                    </>
                                ) : run.run_status === 'post_record_pending' && run.post_record_status !== 'phase2_done' ? (
                                    // post_record_pending, phase 2 not yet completed → show Phase 2 button
                                    <button
                                        className="btn-primary"
                                        style={{ width: '100%', background: '#0891b2' }}
                                        disabled={completingPhase2}
                                        onClick={handleCompletePhase2}
                                    >
                                        <LuCheck size={16} style={{ marginRight: 6 }} />
                                        {completingPhase2
                                            ? (locale === 'ja' ? 'フェーズ2完了中...' : 'Completing Phase 2...')
                                            : (locale === 'ja' ? 'フェーズ2完了（後日記録完了）' : 'Complete Phase 2 (finish post-record)')}
                                    </button>
                                ) : (
                                    // Normal finalize (realtime OR post_record with phase2_done)
                                    <>
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
                            </>
                        )}
                    </div>
                )}

                {/* G-10: 交付記録 — always shown on finalize tab (post-finalize recording) */}
                {activeTab === 'finalize' && (
                    <div className="section-card animate-fade-in" style={{ marginTop: 16 }}>
                        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 14 }}>
                            <label style={{ fontSize: 14, fontWeight: 600 }}>
                                {locale === 'ja' ? '交付記録' : 'Delivery Record'}
                            </label>
                            <span style={{
                                fontSize: 12, fontWeight: 700, padding: '3px 10px', borderRadius: 10,
                                background: run.delivery_status === 'delivered' ? 'rgba(46,125,50,0.1)' : 'rgba(120,144,156,0.12)',
                                color: run.delivery_status === 'delivered' ? 'var(--success)' : 'var(--status-draft)',
                            }}>
                                {run.delivery_status === 'delivered'
                                    ? (locale === 'ja' ? '交付済み' : 'Delivered')
                                    : (locale === 'ja' ? '未交付' : 'Not Delivered')}
                            </span>
                        </div>
                        <div style={{ display: 'grid', gap: 12 }}>
                            <div>
                                <label className="form-label">{locale === 'ja' ? '交付方法' : 'Delivery Method'}</label>
                                <select className="form-select" value={deliveryMethod} onChange={e => setDeliveryMethod(e.target.value)}
                                    disabled={run.delivery_status === 'delivered'}>
                                    <option value="">{locale === 'ja' ? '選択してください' : 'Select'}</option>
                                    <option value="hand">{locale === 'ja' ? '対面交付' : 'In-person'}</option>
                                    <option value="mail">{locale === 'ja' ? '郵送' : 'Mail'}</option>
                                    <option value="email">{locale === 'ja' ? 'メール' : 'Email'}</option>
                                    <option value="digital">{locale === 'ja' ? 'デジタル交付' : 'Digital'}</option>
                                </select>
                            </div>
                            {(deliveryMethod === 'mail' || deliveryMethod === 'digital' || deliveryMethod === 'email') && (
                                <div>
                                    <label className="form-label">{locale === 'ja' ? '参照番号（任意）' : 'Reference No. (optional)'}</label>
                                    <input className="form-input" value={deliveryReference}
                                        onChange={e => setDeliveryReference(e.target.value)}
                                        disabled={run.delivery_status === 'delivered'}
                                        placeholder={locale === 'ja' ? '例: POST-2026-001' : 'e.g. POST-2026-001'} />
                                    <p style={{ fontSize: 11, color: 'var(--text-secondary)', marginTop: 4 }}>
                                        {locale === 'ja' ? '郵送・デジタル交付時の管理番号' : 'Tracking/reference number for mail or digital delivery'}
                                    </p>
                                </div>
                            )}
                            <label style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: run.delivery_status === 'delivered' ? 'default' : 'pointer' }}>
                                <input type="checkbox" checked={deliveryConfirmed}
                                    onChange={e => setDeliveryConfirmed(e.target.checked)}
                                    disabled={run.delivery_status === 'delivered'}
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
                            {run.delivery_status !== 'delivered' && (
                                <button type="button" disabled={savingDelivery || !deliveryMethod} onClick={handleSaveDelivery}
                                    style={{ fontSize: 13, padding: '6px 14px', borderRadius: 6, border: '1px solid #cbd5e1', background: 'white', cursor: 'pointer', width: 'fit-content' }}>
                                    {savingDelivery ? '...' : (locale === 'ja' ? '保存' : 'Save')}
                                </button>
                            )}
                        </div>
                    </div>
                )}

                {/* ═══════════════════════════════════════ */}
                {/* TAB: DOCUMENTS (MS3)                    */}
                {/* ═══════════════════════════════════════ */}
                {activeTab === 'documents' && (
                    <div className="animate-fade-in space-y-6">
                        {/* Load report data button */}
                        {!reportData && (
                            <div className="section-card" style={{ textAlign: 'center', padding: 32 }}>
                                <LuFileText size={32} color="#d1d5db" style={{ marginBottom: 12 }} />
                                <p style={{ fontSize: 14, color: 'var(--text-secondary)', marginBottom: 16 }}>
                                    {locale === 'ja' ? '書面・証跡データを読み込んでください' : 'Load document and audit data'}
                                </p>
                                <button className="btn-primary" onClick={loadReportData} disabled={loadingReport} style={{ fontSize: 13 }}>
                                    {loadingReport ? '...' : (locale === 'ja' ? 'データを読み込む' : 'Load Data')}
                                </button>
                            </div>
                        )}

                        {reportData && (
                            <>
                                {/* ── D-3/D-4: 推奨・決定プラン選択 + 差異理由 ── */}
                                <div className="section-card">
                                    <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 4, color: '#1d4ed8' }}>
                                        {locale === 'ja' ? 'D-3/D-4 推奨・決定プラン + 差異理由' : 'D-3/D-4 Plan Selection + Diff Reason'}
                                    </h3>
                                    <p style={{ fontSize: 12, color: '#6b7280', marginBottom: 14 }}>
                                        {locale === 'ja'
                                            ? '代理店控えの「3軸比較（現在契約／募集人おすすめ／お客様決定）」と差異理由を設定します。差異理由は内部記録のみ（お客様シート非表示）。'
                                            : '3-axis comparison (prior/recommended/decided) and plan difference reason for agency copy only.'}
                                    </p>

                                    {/* Diff warning */}
                                    {(reportData.planDiffExists as boolean) && !(reportData.planDiffReasonRecorded as boolean) && (
                                        <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: '#fffbeb', border: '1px solid #fcd34d', borderRadius: 8, padding: '10px 14px', marginBottom: 14 }}>
                                            <LuTriangle size={16} color="#d97706" />
                                            <span style={{ fontSize: 13, color: '#92400e', fontWeight: 600 }}>
                                                {locale === 'ja' ? '差異理由未記録 — 推奨プランとお客様決定プランが異なります' : 'Plan diff reason not recorded'}
                                            </span>
                                        </div>
                                    )}

                                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
                                        <div>
                                            <label className="form-label">{locale === 'ja' ? '募集人推奨プラン' : 'Recommended Plan'}</label>
                                            <select className="form-select" value={recommendedId}
                                                onChange={e => setRecommendedId(e.target.value)}
                                                disabled={!isEditable}>
                                                <option value="">{locale === 'ja' ? '選択してください' : 'Select'}</option>
                                                {candidates.filter(c => c.status === 'active').map(c => (
                                                    <option key={c.id} value={c.id}>
                                                        {c.insurer_name}{c.product_name ? ` / ${c.product_name}` : ''}{c.annual_premium ? ` ¥${c.annual_premium.toLocaleString()}` : ''} ({c.role ?? 'plan'})
                                                    </option>
                                                ))}
                                            </select>
                                        </div>
                                        <div>
                                            <label className="form-label">{locale === 'ja' ? 'お客様決定プラン' : 'Decided Plan'}</label>
                                            <select className="form-select" value={decidedId}
                                                onChange={e => setDecidedId(e.target.value)}
                                                disabled={!isEditable}>
                                                <option value="">{locale === 'ja' ? '選択してください' : 'Select'}</option>
                                                {candidates.filter(c => c.status === 'active').map(c => (
                                                    <option key={c.id} value={c.id}>
                                                        {c.insurer_name}{c.product_name ? ` / ${c.product_name}` : ''}{c.annual_premium ? ` ¥${c.annual_premium.toLocaleString()}` : ''} ({c.role ?? 'plan'})
                                                    </option>
                                                ))}
                                            </select>
                                        </div>
                                    </div>

                                    {/* Show diff notice + reason input when plans differ */}
                                    {recommendedId && decidedId && recommendedId !== decidedId && (
                                        <div style={{ marginTop: 12 }}>
                                            <label className="form-label">
                                                {locale === 'ja' ? '差異理由（代理店控えのみ・内部記録）' : 'Difference reason (agency copy only)'}
                                                <span style={{ marginLeft: 6, fontSize: 11, color: '#dc2626', fontWeight: 700 }}>
                                                    {!planDiffReason.trim() ? (locale === 'ja' ? '未記録' : 'Not recorded') : ''}
                                                </span>
                                            </label>
                                            <textarea
                                                value={planDiffReason}
                                                onChange={e => setPlanDiffReason(e.target.value)}
                                                disabled={!isEditable}
                                                rows={2}
                                                placeholder={locale === 'ja' ? '例：お客様の予算制約により保険料を優先されました' : 'e.g. Customer prioritized premium due to budget constraints'}
                                                style={{ width: '100%', padding: '8px 10px', borderRadius: 8, border: `1px solid ${!planDiffReason.trim() ? '#fca5a5' : '#e2e8f0'}`, fontSize: 13, resize: 'vertical' }}
                                            />
                                        </div>
                                    )}

                                    {isEditable && (
                                        <button className="btn-primary" onClick={handleSavePlanSelection}
                                            disabled={savingPlanSelection} style={{ marginTop: 12, fontSize: 13 }}>
                                            {savingPlanSelection ? '...' : (locale === 'ja' ? '保存' : 'Save')}
                                        </button>
                                    )}
                                </div>

                                {/* ── D-8: 業務品質チェック ── */}
                                <div className="section-card">
                                    <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 4, color: '#1d4ed8' }}>
                                        {locale === 'ja' ? 'D-8 業務品質チェック（10項目）' : 'D-8 Business Quality Check (10 items)'}
                                    </h3>
                                    <p style={{ fontSize: 12, color: '#6b7280', marginBottom: 14 }}>
                                        {locale === 'ja' ? '既存フラグ・イベントから自動導出。代理店控えに掲載されます。' : 'Auto-derived from existing flags and events. Included in agency copy.'}
                                    </p>
                                    {(() => {
                                        const checks = reportData.qualityChecks as Array<{ id: string; label: string; pass: boolean; note: string }>
                                        const passCount = checks.filter(c => c.pass).length
                                        return (
                                            <>
                                                <div style={{ display: 'flex', gap: 12, marginBottom: 14 }}>
                                                    <div style={{ background: passCount === 10 ? '#f0fdf4' : '#fffbeb', border: `1px solid ${passCount === 10 ? '#86efac' : '#fcd34d'}`, borderRadius: 8, padding: '8px 16px', fontSize: 13, fontWeight: 700, color: passCount === 10 ? '#15803d' : '#92400e' }}>
                                                        {passCount} / 10 {locale === 'ja' ? '項目クリア' : 'items passed'}
                                                    </div>
                                                </div>
                                                <div style={{ display: 'grid', gap: 6 }}>
                                                    {checks.map(c => (
                                                        <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 13, padding: '8px 12px', borderRadius: 8, background: c.pass ? 'rgba(22,163,74,0.06)' : 'rgba(220,38,38,0.06)' }}>
                                                            {c.pass
                                                                ? <LuCircleCheck size={15} color="#16a34a" />
                                                                : <LuCircleX size={15} color="#dc2626" />}
                                                            <span style={{ fontWeight: 600, color: c.pass ? '#15803d' : '#991b1b', minWidth: 180 }}>{c.label}</span>
                                                            <span style={{ fontSize: 11, color: '#9ca3af' }}>{c.note}</span>
                                                        </div>
                                                    ))}
                                                </div>
                                            </>
                                        )
                                    })()}
                                </div>

                                {/* ── D-7: 監査タイムライン ── */}
                                <div className="section-card">
                                    <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 4, color: '#1d4ed8' }}>
                                        {locale === 'ja' ? 'D-7 監査用タイムライン（最大14件）' : 'D-7 Audit Timeline (max 14)'}
                                    </h3>
                                    <p style={{ fontSize: 12, color: '#6b7280', marginBottom: 14 }}>
                                        {locale === 'ja' ? '代理店控えの証跡ページに掲載されます。' : 'Included in agency copy audit page.'}
                                    </p>
                                    {(() => {
                                        const tl = reportData.timeline as Array<{ no: number; occurred_at: string; category: string; label: string; payload_summary: string }>
                                        const CATEGORY_COLOR: Record<string, string> = {
                                            '現状確認': '#6366f1', '記録': '#0891b2', '意向把握': '#d97706',
                                            '比較・案内': '#16a34a', '最終確認': '#dc2626', '確定': '#1d4ed8',
                                        }
                                        return tl.length === 0 ? (
                                            <p style={{ fontSize: 13, color: '#9ca3af' }}>{locale === 'ja' ? '証跡イベントがありません' : 'No audit events'}</p>
                                        ) : (
                                            <div style={{ overflowX: 'auto' }}>
                                                <table className="data-table" style={{ fontSize: 12 }}>
                                                    <thead>
                                                        <tr>
                                                            <th>No.</th>
                                                            <th>{locale === 'ja' ? '日時' : 'Time'}</th>
                                                            <th>{locale === 'ja' ? '区分' : 'Category'}</th>
                                                            <th>{locale === 'ja' ? 'イベント' : 'Event'}</th>
                                                            <th>{locale === 'ja' ? '補足' : 'Notes'}</th>
                                                        </tr>
                                                    </thead>
                                                    <tbody>
                                                        {tl.map(row => (
                                                            <tr key={row.no}>
                                                                <td style={{ fontWeight: 600 }}>{row.no}</td>
                                                                <td style={{ whiteSpace: 'nowrap', color: '#6b7280' }}>
                                                                    {format(new Date(row.occurred_at), 'MM/dd HH:mm')}
                                                                </td>
                                                                <td>
                                                                    <span style={{ fontSize: 11, padding: '2px 8px', borderRadius: 10, fontWeight: 700, background: `${CATEGORY_COLOR[row.category] ?? '#6b7280'}18`, color: CATEGORY_COLOR[row.category] ?? '#6b7280' }}>
                                                                        {row.category}
                                                                    </span>
                                                                </td>
                                                                <td style={{ fontWeight: 600 }}>{row.label}</td>
                                                                <td style={{ color: '#9ca3af', fontFamily: 'monospace', fontSize: 11 }}>{row.payload_summary}</td>
                                                            </tr>
                                                        ))}
                                                    </tbody>
                                                </table>
                                            </div>
                                        )
                                    })()}
                                </div>

                                {/* ── A-3: CSV出力 ── */}
                                <div className="section-card">
                                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
                                        <div>
                                            <h3 style={{ fontSize: 15, fontWeight: 700, color: '#1d4ed8' }}>
                                                {locale === 'ja' ? 'A-3 CSV骨格出力' : 'A-3 CSV Export (Skeleton)'}
                                            </h3>
                                            <p style={{ fontSize: 12, color: '#6b7280', marginTop: 4 }}>
                                                {locale === 'ja'
                                                    ? 'フィールド定義・出力形式の骨格CSVをダウンロードします。完全マッピング・取込処理はPhase2-b。'
                                                    : 'Download field-definition skeleton CSV. Full mapping and import processing = Phase2-b.'}
                                            </p>
                                        </div>
                                        <button className="btn-secondary" onClick={handleDownloadCsv}
                                            style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, whiteSpace: 'nowrap' }}>
                                            <LuDownload size={14} />
                                            {locale === 'ja' ? 'CSV出力' : 'Export CSV'}
                                        </button>
                                    </div>
                                    <div style={{ background: '#f9fafb', borderRadius: 8, padding: '10px 14px', fontSize: 12, color: '#6b7280' }}>
                                        {locale === 'ja' ? `出力フィールド: 案件基本情報 / 意向・同意 / スマホ確認 / プラン選択 / 比較プラン（${candidates.length}件可変） / 証跡サマリー` : `Fields: Run info / Consent / Smartphone / Plan selection / ${candidates.length} plans (variable) / Audit summary`}
                                    </div>
                                </div>

                                {/* ── A-1/A-2 書面出力 ── */}
                                <div className="section-card">
                                    <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 8 }}>
                                        {locale === 'ja' ? '書面出力' : 'Document Output'}
                                    </h3>
                                    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                                        <a
                                            href={`/run/${runId}/print/customer-sheet`}
                                            target="_blank"
                                            rel="noopener noreferrer"
                                            style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', background: '#eff6ff', border: '1px solid #bfdbfe', borderRadius: 8, textDecoration: 'none', color: '#1d4ed8' }}
                                        >
                                            <span style={{ fontSize: 20 }}>📄</span>
                                            <div>
                                                <div style={{ fontSize: 13, fontWeight: 700 }}>
                                                    {locale === 'ja' ? 'A-1 お客様シート（A4 2枚）' : 'A-1 Customer Sheet (A4 2p)'}
                                                </div>
                                                <div style={{ fontSize: 11, color: '#3b82f6', marginTop: 2 }}>
                                                    {locale === 'ja' ? '診断結果・意向把握 ／ 比較表・ご提案・ご選択 - 新しいタブで開く' : 'Diagnosis / Comparison / Plan selection - opens in new tab'}
                                                </div>
                                            </div>
                                        </a>
                                        <a
                                            href={`/run/${runId}/print/agency-report`}
                                            target="_blank"
                                            rel="noopener noreferrer"
                                            style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 14px', background: '#f9fafb', border: '1px solid #e5e7eb', borderRadius: 8, textDecoration: 'none', color: '#374151' }}
                                        >
                                            <span style={{ fontSize: 20 }}>📋</span>
                                            <div>
                                                <div style={{ fontSize: 13, fontWeight: 700 }}>
                                                    {locale === 'ja' ? 'A-2 代理店控え（A4 4枚）' : 'A-2 Agency Copy (A4 4p)'}
                                                </div>
                                                <div style={{ fontSize: 11, color: '#6b7280', marginTop: 2 }}>
                                                    {locale === 'ja' ? '3軸比較・差異・品質チェック・証跡タイムライン・ログ原文 - 新しいタブで開く' : '3-axis compare / diff / quality checks / timeline / raw logs - opens in new tab'}
                                                </div>
                                            </div>
                                        </a>
                                    </div>
                                </div>
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
