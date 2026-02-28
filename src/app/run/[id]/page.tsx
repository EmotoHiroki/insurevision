'use client'

import { useEffect, useState, useCallback } from 'react'
import { useRouter, useParams, useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import type { Run, Candidate, Operator, AuditEvent } from '@/lib/types'
import { format } from 'date-fns'
import {
    LuShield, LuGlobe, LuArrowLeft, LuCheck, LuPlus, LuTrash2, LuStar,
    LuFileCheck, LuTriangleAlert, LuClock, LuUser, LuSave, LuChevronRight,
    LuLock, LuRefreshCw, LuFileText,
} from 'react-icons/lu'

export default function RunDetailPage() {
    const router = useRouter()
    const params = useParams()
    const runId = params.id as string
    const { t, toggleLocale, locale } = useLocale()

    const [run, setRun] = useState<Run | null>(null)
    const [candidates, setCandidates] = useState<Candidate[]>([])
    const [auditEvents, setAuditEvents] = useState<AuditEvent[]>([])
    const [operator, setOperator] = useState<Operator | null>(null)
    const [loading, setLoading] = useState(true)
    const [saving, setSaving] = useState(false)
    const searchParams = useSearchParams()
    const urlTab = searchParams.get('tab') as 'details' | 'candidates' | 'audit' | null
    const [activeTab, setActiveTab] = useState<'details' | 'candidates' | 'audit'>(urlTab || 'details')
    const [toast, setToast] = useState<{ msg: string; type: string } | null>(null)

    // Candidate form
    const [newInsurerName, setNewInsurerName] = useState('')
    const [newProductName, setNewProductName] = useState('')
    const [newPremium, setNewPremium] = useState('')

    const showToast = (msg: string, type = 'success') => {
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

        const { data: candData } = await supabase.from('candidate').select('*').eq('run_id', runId).order('slot_no')
        setCandidates((candData as Candidate[]) || [])

        const { data: auditData } = await supabase
            .from('audit_event').select('*').eq('run_id', runId).order('occurred_at', { ascending: false }).limit(50)
        setAuditEvents((auditData as AuditEvent[]) || [])

        setLoading(false)
    }, [runId, router])

    useEffect(() => { loadData() }, [loadData])

    const handleUpdateRun = async (updates: Partial<Run>) => {
        if (!run || !operator) return
        setSaving(true)
        try {
            const supabase = createClient()
            const { data, error } = await supabase.from('run').update(updates).eq('id', runId).select().single()
            if (error) throw error
            setRun(data as Run)

            await supabase.from('audit_event').insert({
                run_id: runId, entity_type: 'run', entity_id: runId,
                event_type: 'updated', operator_id: operator.id,
            })
            showToast(t('success'))
        } catch (err: unknown) {
            showToast(err instanceof Error ? err.message : t('error'), 'error')
        } finally { setSaving(false) }
    }

    const handleAddCandidate = async () => {
        if (!newInsurerName.trim() || !operator || !run) return
        setSaving(true)
        try {
            const supabase = createClient()
            const nextSlot = candidates.length > 0 ? Math.max(...candidates.map(c => c.slot_no)) + 1 : 1
            const { data, error } = await supabase.from('candidate').insert({
                run_id: runId, slot_no: nextSlot, insurer_name: newInsurerName.trim(),
                product_name: newProductName.trim() || null,
                annual_premium: newPremium ? parseInt(newPremium) : null,
            }).select().single()
            if (error) throw error

            await supabase.from('audit_event').insert({
                run_id: runId, entity_type: 'candidate', entity_id: data.id,
                event_type: 'created', operator_id: operator.id,
            })

            setCandidates(prev => [...prev, data as Candidate])
            setNewInsurerName('')
            setNewProductName('')
            setNewPremium('')
            showToast(t('success'))
        } catch (err: unknown) {
            showToast(err instanceof Error ? err.message : t('error'), 'error')
        } finally { setSaving(false) }
    }

    const handleExcludeCandidate = async (candidateId: string) => {
        if (!operator) return
        const reason = prompt(locale === 'ja' ? '除外理由を入力' : 'Enter exclusion reason')
        if (!reason) return
        try {
            const supabase = createClient()
            await supabase.from('candidate').update({
                status: 'excluded', excluded_reason: reason, excluded_by: operator.id,
                excluded_at: new Date().toISOString(),
            }).eq('id', candidateId)

            await supabase.from('audit_event').insert({
                run_id: runId, entity_type: 'candidate', entity_id: candidateId,
                event_type: 'updated', field_name: 'status', new_value: { value: 'excluded' },
                operator_id: operator.id,
            })
            await loadData()
            showToast(t('success'))
        } catch (err: unknown) {
            showToast(err instanceof Error ? err.message : t('error'), 'error')
        }
    }

    const handleSetRecommended = async (candidateId: string) => {
        await handleUpdateRun({ recommended_candidate_id: candidateId, compliance_mode: 'ro_recommendation' } as Partial<Run>)
        await loadData()
    }

    const handleSetFinal = async (candidateId: string) => {
        await handleUpdateRun({ final_candidate_id: candidateId } as Partial<Run>)
        await loadData()
    }

    const handleFinalize = async () => {
        if (!run || !operator) return
        if (!confirm(t('finalizeConfirmBody'))) return
        setSaving(true)
        try {
            const supabase = createClient()
            // Set to finalizing
            await supabase.from('run').update({
                run_status: 'finalizing' as const,
            }).eq('id', runId)

            // Attempt finalize
            const complianceMode = run.recommended_candidate_id ? 'ro_recommendation'
                : run.compare_presented_at ? 'i_compare_info' : 'none'

            const { error } = await supabase.from('run').update({
                run_status: 'finalized' as const,
                finalized_at: new Date().toISOString(),
                finalized_by: operator.id,
                compliance_mode: complianceMode,
            }).eq('id', runId)

            if (error) {
                // Set to failed
                await supabase.from('run').update({ run_status: 'finalizing_failed' as const }).eq('id', runId)
                throw error
            }

            await supabase.from('audit_event').insert({
                run_id: runId, entity_type: 'run', entity_id: runId,
                event_type: 'finalized', operator_id: operator.id,
            })

            showToast(t('finalizeSuccess'))
            await loadData()
        } catch (err: unknown) {
            showToast(err instanceof Error ? err.message : t('finalizeFailed'), 'error')
        } finally { setSaving(false) }
    }

    const handleRecordDelivery = async (method: string) => {
        if (!operator) return
        await handleUpdateRun({
            delivered_at: new Date().toISOString(),
            delivery_method: method,
            delivered_recorded_at: new Date().toISOString(),
            delivered_recorded_by: operator.id,
        } as Partial<Run>)
        await loadData()
    }

    if (loading || !run) {
        return (
            <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'var(--surface)' }}>
                <span className="animate-pulse-soft" style={{ fontSize: 16, color: 'var(--text-secondary)' }}>{t('loading')}</span>
            </div>
        )
    }

    const isEditable = run.run_status === 'draft'
    const activeCandidates = candidates.filter(c => c.status === 'active')

    const statusLabel = (s: string) => {
        const map: Record<string, string> = {
            draft: t('draft'), finalizing: t('finalizing'), finalized: t('finalized'),
            finalizing_failed: t('finalizingFailed'), cancelled: t('cancelled'),
        }
        return map[s] || s
    }

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
                        padding: '3px 10px', borderRadius: 10, fontSize: 12, fontWeight: 600, marginLeft: 8
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
                    <button className="btn-secondary" onClick={loadData} style={{ padding: '6px 10px', background: 'rgba(255,255,255,0.1)', border: 'none', color: 'white', borderRadius: 6, cursor: 'pointer' }}>
                        <LuRefreshCw size={16} />
                    </button>
                </div>
            </header>

            <div style={{ maxWidth: 1280, margin: '0 auto', padding: 28 }}>
                {/* Tabs */}
                <div style={{ display: 'flex', gap: 4, marginBottom: 24, background: 'white', borderRadius: 10, padding: 4, boxShadow: '0 1px 3px rgba(0,0,0,0.04)' }}>
                    {([
                        { key: 'details', label: t('runDetails'), icon: LuFileText },
                        { key: 'candidates', label: `${t('candidates')} (${activeCandidates.length})`, icon: LuStar },
                        { key: 'audit', label: `${t('auditLog')} (${auditEvents.length})`, icon: LuClock },
                    ] as const).map(tab => (
                        <button
                            key={tab.key}
                            onClick={() => setActiveTab(tab.key)}
                            style={{
                                flex: 1, padding: '10px 16px', border: 'none', borderRadius: 8, cursor: 'pointer',
                                fontWeight: 500, fontSize: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
                                background: activeTab === tab.key ? 'var(--primary)' : 'transparent',
                                color: activeTab === tab.key ? 'white' : 'var(--text-secondary)',
                            }}
                        >
                            <tab.icon size={16} /> {tab.label}
                        </button>
                    ))}
                </div>

                {/* Details Tab */}
                {activeTab === 'details' && (
                    <div className="animate-fade-in">
                        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                            {/* Basic Info */}
                            <div className="section-card">
                                <h3 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16, display: 'flex', alignItems: 'center', gap: 8 }}>
                                    <LuUser size={18} color="var(--primary)" /> {t('basicInfo')}
                                </h3>
                                <div style={{ display: 'grid', gap: 12 }}>
                                    <div><span className="form-label">{t('customerType')}</span>
                                        <div>{run.customer_type === 'individual' ? t('individual') : t('corporate')}</div></div>
                                    <div><span className="form-label">{t('customerRef')}</span><div>{run.customer_ref}</div></div>
                                    <div><span className="form-label">{t('runType')}</span>
                                        <div>{run.run_type === 'new_contract' ? t('newContract') : t('renewal')}</div></div>
                                    <div><span className="form-label">{t('kycConfirmed')}</span>
                                        <div>{run.kyc_confirmed ? '✓' : '—'}</div></div>
                                    <div><span className="form-label">{t('createdAt')}</span>
                                        <div style={{ fontSize: 13 }}>{format(new Date(run.created_at), 'yyyy/MM/dd HH:mm')}</div></div>
                                </div>
                            </div>

                            {/* Status & Compliance */}
                            <div className="section-card">
                                <h3 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16, display: 'flex', alignItems: 'center', gap: 8 }}>
                                    <LuFileCheck size={18} color="var(--primary)" /> {t('status')} & {t('complianceMode')}
                                </h3>
                                <div style={{ display: 'grid', gap: 12 }}>
                                    <div><span className="form-label">{t('status')}</span>
                                        <span className={`status-${run.run_status}`} style={{ padding: '4px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600 }}>
                                            {statusLabel(run.run_status)}
                                        </span>
                                    </div>
                                    <div><span className="form-label">{t('complianceMode')}</span>
                                        <div>{run.compliance_mode
                                            ? run.compliance_mode === 'ro_recommendation' ? t('roRecommendation')
                                                : run.compliance_mode === 'i_compare_info' ? t('iCompareInfo')
                                                    : t('complianceNone')
                                            : '—'}</div>
                                    </div>
                                    {run.finalized_at && (
                                        <div><span className="form-label">{t('finalizedAt')}</span>
                                            <div style={{ fontSize: 13 }}>{format(new Date(run.finalized_at), 'yyyy/MM/dd HH:mm')}</div></div>
                                    )}
                                    <div><span className="form-label">{t('signaturePolicy')}</span><div>{run.signature_policy}</div></div>
                                </div>
                            </div>

                            {/* Intention */}
                            <div className="section-card" style={{ gridColumn: '1 / -1' }}>
                                <h3 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>{t('intentionConfirmation')}</h3>
                                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 12 }}>
                                    <div><span className="form-label">{locale === 'ja' ? '顧客意向' : 'Customer Decision'}</span>
                                        <div>{run.customer_decision || '—'}</div></div>
                                    <div><span className="form-label">{t('intentionConfirmMethod')}</span>
                                        <div>{run.intention_confirm_method || '—'}</div></div>
                                    <div><span className="form-label">{t('priorityFactors')}</span>
                                        <div>{run.priority_factors?.join(', ') || '—'}</div></div>
                                </div>
                                {run.intention_summary && (
                                    <div style={{ marginTop: 12 }}><span className="form-label">{t('intentionSummary')}</span>
                                        <div style={{ background: '#f9fafb', padding: 12, borderRadius: 8 }}>{run.intention_summary}</div></div>
                                )}
                            </div>

                            {/* Delivery (finalized only) */}
                            {run.run_status === 'finalized' && (
                                <div className="section-card" style={{ gridColumn: '1 / -1' }}>
                                    <h3 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>{t('pdfDelivery')}</h3>
                                    {run.delivered_at ? (
                                        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                                            <div><span className="form-label">{t('deliveredAt')}</span>
                                                <div>{format(new Date(run.delivered_at), 'yyyy/MM/dd HH:mm')}</div></div>
                                            <div><span className="form-label">{t('deliveryMethod')}</span><div>{run.delivery_method || '—'}</div></div>
                                        </div>
                                    ) : (
                                        <div>
                                            <p style={{ color: 'var(--text-secondary)', marginBottom: 12 }}>
                                                {locale === 'ja' ? '交付方法を選んで記録してください' : 'Select delivery method'}
                                            </p>
                                            <div style={{ display: 'flex', gap: 8 }}>
                                                {['in_person', 'email', 'mail', 'other'].map(m => (
                                                    <button key={m} className="btn-secondary" onClick={() => handleRecordDelivery(m)} style={{ fontSize: 13, padding: '8px 14px' }}>
                                                        {t((m === 'in_person' ? 'inPerson' : m === 'email' ? 'emailDelivery' : m === 'mail' ? 'mailDelivery' : 'otherDelivery') as 'inPerson')}
                                                    </button>
                                                ))}
                                            </div>
                                        </div>
                                    )}
                                </div>
                            )}
                        </div>

                        {/* Actions */}
                        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12, marginTop: 24 }}>
                            {isEditable && (
                                <>
                                    <button className="btn-danger" onClick={() => handleUpdateRun({ run_status: 'cancelled' } as Partial<Run>)} disabled={saving}>
                                        {t('cancel')}
                                    </button>
                                    <button className="btn-primary" onClick={handleFinalize} disabled={saving || !run.customer_decision || activeCandidates.length === 0}>
                                        <LuLock size={16} /> {t('finalize')}
                                    </button>
                                </>
                            )}
                            {run.run_status === 'finalizing_failed' && (
                                <button className="btn-primary" onClick={handleFinalize} disabled={saving}>
                                    <LuRefreshCw size={16} /> {locale === 'ja' ? '確定を再試行' : 'Retry Finalize'}
                                </button>
                            )}
                        </div>
                    </div>
                )}

                {/* Candidates Tab */}
                {activeTab === 'candidates' && (
                    <div className="animate-fade-in">
                        {/* Add candidate form */}
                        {isEditable && (
                            <div className="section-card" style={{ marginBottom: 20 }}>
                                <h3 style={{ fontSize: 16, fontWeight: 600, marginBottom: 16 }}>
                                    <LuPlus size={16} style={{ marginRight: 8 }} />
                                    {t('addCandidate')}
                                </h3>
                                <div style={{ display: 'grid', gridTemplateColumns: '2fr 2fr 1fr auto', gap: 12, alignItems: 'end' }}>
                                    <div>
                                        <label className="form-label">{t('insurerName')} <span className="badge-required">{t('required')}</span></label>
                                        <input className="form-input" value={newInsurerName} onChange={e => setNewInsurerName(e.target.value)}
                                            placeholder={locale === 'ja' ? '例: 東京海上日動' : 'e.g. Tokio Marine'} />
                                    </div>
                                    <div>
                                        <label className="form-label">{t('productName')}</label>
                                        <input className="form-input" value={newProductName} onChange={e => setNewProductName(e.target.value)}
                                            placeholder={locale === 'ja' ? '例: TAP' : 'e.g. TAP'} />
                                    </div>
                                    <div>
                                        <label className="form-label">{t('annualPremium')}</label>
                                        <input className="form-input" type="number" value={newPremium} onChange={e => setNewPremium(e.target.value)} placeholder="¥" />
                                    </div>
                                    <button className="btn-accent" onClick={handleAddCandidate} disabled={saving || !newInsurerName.trim()} style={{ height: 42 }}>
                                        <LuPlus size={16} /> {t('add')}
                                    </button>
                                </div>
                            </div>
                        )}

                        {/* Candidate cards — fixed sort order (slot_no) as per requirements */}
                        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 16 }}>
                            {candidates.map(c => (
                                <div key={c.id} className="card-hover" style={{
                                    background: 'white', borderRadius: 12, padding: 20,
                                    boxShadow: '0 1px 4px rgba(0,0,0,0.04)',
                                    opacity: c.status === 'excluded' ? 0.5 : 1,
                                    borderLeft: `4px solid ${run.final_candidate_id === c.id ? 'var(--success)'
                                        : run.recommended_candidate_id === c.id ? 'var(--accent)'
                                            : c.status === 'excluded' ? 'var(--status-cancelled)'
                                                : 'var(--border)'
                                        }`,
                                }}>
                                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'start', marginBottom: 12 }}>
                                        <div>
                                            <span style={{ fontSize: 12, color: 'var(--text-secondary)' }}>
                                                {c.slot_no === 1 ? t('currentContract') : `${t('candidateLabel')} ${c.slot_no}`}
                                            </span>
                                            {run.recommended_candidate_id === c.id && (
                                                <span style={{ marginLeft: 8, fontSize: 11, background: 'rgba(0,188,212,0.12)', color: 'var(--accent)', padding: '2px 8px', borderRadius: 10, fontWeight: 600 }}>
                                                    {t('recommend')}
                                                </span>
                                            )}
                                            {run.final_candidate_id === c.id && (
                                                <span style={{ marginLeft: 8, fontSize: 11, background: 'rgba(46,125,50,0.12)', color: 'var(--success)', padding: '2px 8px', borderRadius: 10, fontWeight: 600 }}>
                                                    {t('finalize')}
                                                </span>
                                            )}
                                        </div>
                                        {c.status === 'excluded' && (
                                            <span style={{ fontSize: 11, background: 'rgba(189,189,189,0.15)', color: '#999', padding: '2px 8px', borderRadius: 10 }}>
                                                {t('excluded')}
                                            </span>
                                        )}
                                    </div>
                                    <div style={{ fontSize: 16, fontWeight: 600, marginBottom: 4 }}>{c.insurer_name}</div>
                                    {c.product_name && <div style={{ fontSize: 13, color: 'var(--text-secondary)' }}>{c.product_name}</div>}
                                    {c.annual_premium && (
                                        <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--primary)', marginTop: 8 }}>
                                            ¥{c.annual_premium.toLocaleString()}
                                        </div>
                                    )}
                                    {c.excluded_reason && (
                                        <div style={{ fontSize: 12, color: 'var(--error)', marginTop: 8, background: 'rgba(198,40,40,0.05)', padding: '6px 10px', borderRadius: 6 }}>
                                            {c.excluded_reason}
                                        </div>
                                    )}

                                    {isEditable && c.status === 'active' && (
                                        <div style={{ display: 'flex', gap: 6, marginTop: 14, flexWrap: 'wrap' }}>
                                            <button onClick={() => handleSetRecommended(c.id)} style={{
                                                fontSize: 12, padding: '5px 10px', border: '1px solid var(--accent)', color: 'var(--accent)',
                                                background: 'transparent', borderRadius: 6, cursor: 'pointer',
                                            }}>
                                                <LuStar size={12} style={{ marginRight: 4 }} /> {t('recommend')}
                                            </button>
                                            <button onClick={() => handleSetFinal(c.id)} style={{
                                                fontSize: 12, padding: '5px 10px', border: '1px solid var(--success)', color: 'var(--success)',
                                                background: 'transparent', borderRadius: 6, cursor: 'pointer',
                                            }}>
                                                <LuCheck size={12} style={{ marginRight: 4 }} /> {t('selectFinal')}
                                            </button>
                                            <button onClick={() => handleExcludeCandidate(c.id)} style={{
                                                fontSize: 12, padding: '5px 10px', border: '1px solid var(--error)', color: 'var(--error)',
                                                background: 'transparent', borderRadius: 6, cursor: 'pointer',
                                            }}>
                                                <LuTrash2 size={12} style={{ marginRight: 4 }} /> {t('excludeCandidate')}
                                            </button>
                                        </div>
                                    )}
                                </div>
                            ))}
                        </div>

                        {candidates.length === 0 && (
                            <div className="section-card" style={{ textAlign: 'center', padding: 48 }}>
                                <LuStar size={40} color="#ddd" />
                                <p style={{ color: 'var(--text-secondary)', marginTop: 12 }}>{t('noDataFound')}</p>
                            </div>
                        )}
                    </div>
                )}

                {/* Audit Tab */}
                {activeTab === 'audit' && (
                    <div className="animate-fade-in">
                        <div style={{ background: 'white', borderRadius: 12, boxShadow: '0 1px 4px rgba(0,0,0,0.04)', overflow: 'hidden' }}>
                            {auditEvents.length === 0 ? (
                                <div style={{ padding: 48, textAlign: 'center', color: 'var(--text-secondary)' }}>
                                    <LuClock size={40} color="#ddd" />
                                    <p style={{ marginTop: 12 }}>{t('noDataFound')}</p>
                                </div>
                            ) : (
                                <table className="data-table">
                                    <thead>
                                        <tr>
                                            <th>{locale === 'ja' ? '日時' : 'Time'}</th>
                                            <th>{locale === 'ja' ? 'イベント' : 'Event'}</th>
                                            <th>{locale === 'ja' ? '対象' : 'Entity'}</th>
                                            <th>{locale === 'ja' ? 'フィールド' : 'Field'}</th>
                                            <th>{locale === 'ja' ? '新値' : 'New Value'}</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {auditEvents.map(evt => (
                                            <tr key={evt.id}>
                                                <td style={{ fontSize: 12, color: 'var(--text-secondary)', whiteSpace: 'nowrap' }}>
                                                    {format(new Date(evt.occurred_at), 'MM/dd HH:mm:ss')}
                                                </td>
                                                <td>
                                                    <span style={{
                                                        fontSize: 12, padding: '2px 8px', borderRadius: 10, fontWeight: 600,
                                                        background: evt.event_type === 'finalized' ? 'rgba(102,187,106,0.12)' : evt.event_type === 'created' ? 'rgba(2,119,189,0.12)' : 'rgba(0,0,0,0.05)',
                                                        color: evt.event_type === 'finalized' ? 'var(--success)' : evt.event_type === 'created' ? 'var(--info)' : 'var(--text-secondary)',
                                                    }}>
                                                        {evt.event_type}
                                                    </span>
                                                </td>
                                                <td style={{ fontSize: 13 }}>{evt.entity_type}</td>
                                                <td style={{ fontSize: 13, color: 'var(--text-secondary)' }}>{evt.field_name || '—'}</td>
                                                <td style={{ fontSize: 12, color: 'var(--text-secondary)', maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                                    {evt.new_value ? JSON.stringify(evt.new_value) : '—'}
                                                </td>
                                            </tr>
                                        ))}
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
