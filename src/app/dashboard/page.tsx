'use client'

import { useEffect, useState, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import type { Run, Operator, CasePhase } from '@/lib/types'
import { categoryLabel } from '@/lib/insurance/categories'
import { format } from 'date-fns'
import {
    LuShield, LuGlobe, LuLogOut, LuPlus, LuChevronRight,
    LuFilePenLine, LuCircleCheck, LuTriangleAlert, LuList, LuRefreshCw,
} from 'react-icons/lu'

export default function DashboardPage() {
    const router = useRouter()
    const { t, toggleLocale, locale } = useLocale()
    const [runs, setRuns] = useState<Run[]>([])
    const [operator, setOperator] = useState<Operator | null>(null)
    const [loading, setLoading] = useState(true)
    const [statusFilter, setStatusFilter] = useState<string>('all')
    const [phaseFilter, setPhaseFilter] = useState<string>('all')

    const loadData = useCallback(async () => {
        setLoading(true)
        const supabase = createClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) { router.push('/login'); return }

        const { data: opData } = await supabase
            .from('operator')
            .select('*')
            .eq('auth_user_id', user.id)
            .maybeSingle()
        if (opData) setOperator(opData)

        const { data: runsData } = await supabase
            .from('run')
            .select('*')
            .order('created_at', { ascending: false })
        setRuns((runsData as Run[]) || [])
        setLoading(false)
    }, [router])

    useEffect(() => {
        const run = async () => { await loadData() }
        run()
    }, [loadData])

    const handleLogout = async () => {
        const supabase = createClient()
        await supabase.auth.signOut()
        router.push('/login')
        router.refresh()
    }

    const filteredRuns = runs.filter(r =>
        (statusFilter === 'all' || r.run_status === statusFilter) &&
        (phaseFilter === 'all' || (r.case_phase ?? 'preparing') === phaseFilter),
    )

    // Phase2-b-0: 案件フェーズ（準備済 / 面談中 / 完了）
    const casePhaseMeta: Record<CasePhase, { ja: string; en: string; color: string }> = {
        preparing:  { ja: '準備済', en: 'Preparing',  color: 'var(--status-draft)' },
        in_meeting: { ja: '面談中', en: 'In meeting', color: 'var(--info)' },
        completed:  { ja: '完了',   en: 'Completed',  color: 'var(--status-finalized)' },
    }
    const casePhaseLabel = (phase: CasePhase) =>
        locale === 'ja' ? casePhaseMeta[phase].ja : casePhaseMeta[phase].en

    const counts = {
        draft: runs.filter(r => r.run_status === 'draft').length,
        finalized: runs.filter(r => r.run_status === 'finalized').length,
        archived: runs.filter(r => r.run_status === 'archived').length,
        total: runs.length,
    }

    const statusLabel = (status: string) => {
        const map: Record<string, string> = {
            draft: t('draft'),
            finalized: t('finalized'),
            archived: t('archived'),
        }
        return map[status] || status
    }

    return (
        <div style={{ minHeight: '100vh', background: 'var(--surface)' }}>
            {/* Header */}
            <header style={{
                background: 'var(--primary)',
                color: 'white',
                padding: '0 24px',
                height: 56,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                boxShadow: '0 2px 8px rgba(0,0,0,0.15)',
            }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                    <div style={{
                        width: 32, height: 32,
                        background: 'linear-gradient(135deg, var(--primary), var(--accent))',
                        borderRadius: 8, display: 'flex', alignItems: 'center', justifyContent: 'center',
                    }}>
                        <LuShield size={18} color="white" />
                    </div>
                    <span style={{ fontSize: 18, fontWeight: 600 }}>{t('appTitle')}</span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
                    <button onClick={toggleLocale} style={{
                        background: 'rgba(255,255,255,0.1)', border: 'none', color: 'rgba(255,255,255,0.8)',
                        padding: '6px 12px', borderRadius: 6, cursor: 'pointer', display: 'flex',
                        alignItems: 'center', gap: 4, fontSize: 12,
                    }}>
                        <LuGlobe size={14} />
                        {locale === 'ja' ? 'EN' : 'JA'}
                    </button>
                    {operator && (
                        <span style={{ fontSize: 13, opacity: 0.8 }}>{operator.name}</span>
                    )}
                    <button onClick={handleLogout} style={{
                        background: 'rgba(255,255,255,0.1)', border: 'none', color: 'rgba(255,255,255,0.8)',
                        padding: '6px 10px', borderRadius: 6, cursor: 'pointer',
                    }}>
                        <LuLogOut size={16} />
                    </button>
                </div>
            </header>

            <main style={{ padding: 28, maxWidth: 1280, margin: '0 auto' }}>
                {/* Title row */}
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 24 }}>
                    <h1 style={{ fontSize: 24, fontWeight: 700, color: 'var(--primary-dark)', margin: 0 }}>
                        {t('runList')}
                    </h1>
                    <div style={{ display: 'flex', gap: 10 }}>
                        <button className="btn-secondary" onClick={loadData} style={{ padding: '8px 14px' }}>
                            <LuRefreshCw size={16} />
                        </button>
                        <button className="btn-primary" onClick={() => router.push('/run/new')}>
                            <LuPlus size={16} />
                            {t('newRun')}
                        </button>
                    </div>
                </div>

                {/* Stats */}
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 28 }}>
                    {[
                        { label: t('draft'), count: counts.draft, color: 'var(--status-draft)', icon: LuFilePenLine },
                        { label: t('finalized'), count: counts.finalized, color: 'var(--status-finalized)', icon: LuCircleCheck },
                        { label: t('archived'), count: counts.archived, color: 'var(--text-secondary)', icon: LuTriangleAlert },
                        { label: t('all'), count: counts.total, color: 'var(--info)', icon: LuList },
                    ].map((stat, i) => (
                        <div key={i} className="card-hover" style={{
                            background: 'white', borderRadius: 12, padding: 20,
                            display: 'flex', alignItems: 'center', gap: 16,
                            boxShadow: `0 2px 10px ${stat.color}22`,
                        }}>
                            <div style={{
                                width: 44, height: 44, borderRadius: 10,
                                background: `${stat.color}15`,
                                display: 'flex', alignItems: 'center', justifyContent: 'center',
                            }}>
                                <stat.icon size={22} color={stat.color} />
                            </div>
                            <div>
                                <div style={{ fontSize: 26, fontWeight: 700, color: stat.color }}>{stat.count}</div>
                                <div style={{ fontSize: 12, color: 'var(--text-secondary)' }}>{stat.label}</div>
                            </div>
                        </div>
                    ))}
                </div>

                {/* Filter tabs */}
                <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
                    {['all', 'draft', 'finalized', 'archived'].map(s => (
                        <button
                            key={s}
                            onClick={() => setStatusFilter(s)}
                            style={{
                                padding: '6px 16px', borderRadius: 20, border: 'none', fontSize: 13, fontWeight: 500,
                                cursor: 'pointer', transition: '0.2s',
                                background: statusFilter === s ? 'var(--primary)' : 'white',
                                color: statusFilter === s ? 'white' : 'var(--text-secondary)',
                                boxShadow: statusFilter === s ? '0 2px 8px rgba(26,35,126,0.25)' : '0 1px 3px rgba(0,0,0,0.06)',
                            }}
                        >
                            {s === 'all' ? t('all') : statusLabel(s)}
                        </button>
                    ))}
                </div>

                {/* Phase2-b-0: 案件フェーズ フィルタ */}
                <div style={{ display: 'flex', gap: 8, marginBottom: 16, alignItems: 'center' }}>
                    <span style={{ fontSize: 12, color: 'var(--text-secondary)', marginRight: 4 }}>
                        {locale === 'ja' ? '案件フェーズ' : 'Case phase'}
                    </span>
                    {(['all', 'preparing', 'in_meeting', 'completed'] as const).map(p => (
                        <button
                            key={p}
                            onClick={() => setPhaseFilter(p)}
                            style={{
                                padding: '5px 14px', borderRadius: 20, border: 'none', fontSize: 12, fontWeight: 500,
                                cursor: 'pointer', transition: '0.2s',
                                background: phaseFilter === p ? 'var(--primary)' : 'white',
                                color: phaseFilter === p ? 'white' : 'var(--text-secondary)',
                                boxShadow: phaseFilter === p ? '0 2px 8px rgba(26,35,126,0.25)' : '0 1px 3px rgba(0,0,0,0.06)',
                            }}
                        >
                            {p === 'all' ? t('all') : casePhaseLabel(p)}
                        </button>
                    ))}
                </div>

                {/* Table */}
                <div style={{
                    background: 'white', borderRadius: 12,
                    boxShadow: '0 1px 4px rgba(0,0,0,0.04)', overflow: 'hidden',
                }}>
                    {loading ? (
                        <div style={{ padding: 48, textAlign: 'center', color: 'var(--text-secondary)' }}>
                            <span className="animate-pulse-soft">{t('loading')}</span>
                        </div>
                    ) : filteredRuns.length === 0 ? (
                        <div style={{ padding: 48, textAlign: 'center', color: 'var(--text-secondary)' }}>
                            <LuList size={40} style={{ opacity: 0.3, marginBottom: 12 }} />
                            <p>{t('noDataFound')}</p>
                        </div>
                    ) : (
                        <table className="data-table">
                            <thead>
                                <tr>
                                    <th>{t('status')}</th>
                                    <th>{locale === 'ja' ? '案件フェーズ' : 'Phase'}</th>
                                    <th>{locale === 'ja' ? '種目' : 'Category'}</th>
                                    <th>{t('customerRef')}</th>
                                    <th>{t('customerType')}</th>
                                    <th>{t('runType')}</th>
                                    <th>{t('complianceMode')}</th>
                                    <th>{t('createdAt')}</th>
                                    <th></th>
                                </tr>
                            </thead>
                            <tbody>
                                {filteredRuns.map(run => (
                                    <tr key={run.id} style={{ cursor: 'pointer' }} onClick={() => router.push(`/run/${run.id}`)}>
                                        <td>
                                            <span className={`status-${run.run_status}`} style={{
                                                padding: '4px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600,
                                            }}>
                                                {statusLabel(run.run_status)}
                                            </span>
                                        </td>
                                        <td>
                                            {(() => {
                                                const phase = (run.case_phase ?? 'preparing') as CasePhase
                                                return (
                                                    <span style={{
                                                        padding: '4px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600,
                                                        background: `${casePhaseMeta[phase].color}18`,
                                                        color: casePhaseMeta[phase].color,
                                                    }}>
                                                        {casePhaseLabel(phase)}
                                                    </span>
                                                )
                                            })()}
                                        </td>
                                        <td style={{ fontSize: 13 }}>
                                            {run.insurance_category_code
                                                ? categoryLabel(run.insurance_category_code, locale)
                                                : '—'}
                                        </td>
                                        <td style={{ fontWeight: 500 }}>{run.customer_ref}</td>
                                        <td>{run.customer_type === 'individual' ? t('individual') : t('corporate')}</td>
                                        <td>{run.run_type === 'new_contract' ? t('newContract') : t('renewal')}</td>
                                        <td style={{ fontSize: 13, color: 'var(--text-secondary)' }}>
                                            {run.compliance_mode
                                                ? run.compliance_mode === 'full' ? t('complianceFull')
                                                    : t('complianceException')
                                                : '—'}
                                        </td>
                                        <td style={{ fontSize: 13, color: 'var(--text-secondary)' }}>
                                            {format(new Date(run.created_at), 'yyyy/MM/dd HH:mm')}
                                        </td>
                                        <td>
                                            <LuChevronRight size={16} color="var(--text-secondary)" />
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    )}
                </div>
            </main>
        </div>
    )
}
