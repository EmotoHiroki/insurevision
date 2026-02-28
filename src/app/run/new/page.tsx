'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import {
    LuShield, LuGlobe, LuArrowLeft, LuChevronRight, LuUser, LuBuilding,
    LuFilePlus, LuRefreshCw, LuCheck, LuSave,
} from 'react-icons/lu'

export default function NewRunPage() {
    const router = useRouter()
    const { t, toggleLocale, locale } = useLocale()
    const [step, setStep] = useState(0)
    const [loading, setLoading] = useState(false)
    const [error, setError] = useState('')

    // Form state
    const [customerType, setCustomerType] = useState<'individual' | 'corporate'>('individual')
    const [customerRef, setCustomerRef] = useState('')
    const [runType, setRunType] = useState<'new_contract' | 'renewal'>('new_contract')
    const [kycConfirmed, setKycConfirmed] = useState(false)
    const [isTest, setIsTest] = useState(false)

    // Step 2: Intention
    const [customerDecision, setCustomerDecision] = useState('')
    const [intentionMethod, setIntentionMethod] = useState('')
    const [intentionSummary, setIntentionSummary] = useState('')
    const [priorityFactors, setPriorityFactors] = useState<string[]>([])

    const steps = [t('basicInfo'), t('intentionConfirmation'), t('candidates'), t('finalize')]

    const handleCreateRun = async () => {
        if (!customerRef.trim()) { setError(t('fieldRequired')); return }
        setLoading(true)
        setError('')
        try {
            const supabase = createClient()
            const { data: { user } } = await supabase.auth.getUser()
            if (!user) throw new Error('Not authenticated')

            const { data: op } = await supabase
                .from('operator').select('*').eq('auth_user_id', user.id).single()

            const { data: run, error: err } = await supabase.from('run').insert({
                agency_id: op.agency_id,
                operator_id: op.id,
                customer_type: customerType,
                customer_ref: customerRef.trim(),
                run_type: runType,
                kyc_confirmed: kycConfirmed,
                is_test: isTest,
                customer_decision: customerDecision || null,
                intention_confirm_method: intentionMethod || null,
                intention_summary: intentionSummary || null,
                priority_factors: priorityFactors.length > 0 ? priorityFactors : null,
                core_logic_version: '1.0.0',
            }).select().single()

            if (err) throw err

            // Add primary participant
            await supabase.from('run_participant').insert({
                run_id: run.id, operator_id: op.id, role: 'primary',
            })

            // Audit log
            await supabase.from('audit_event').insert({
                run_id: run.id, entity_type: 'run', entity_id: run.id,
                event_type: 'created', operator_id: op.id,
            })

            router.push(`/run/${run.id}?tab=candidates`)
        } catch (err: unknown) {
            setError(err instanceof Error ? err.message : t('error'))
        } finally { setLoading(false) }
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
                    <span style={{ fontWeight: 600 }}>{t('newRun')}</span>
                </div>
                <button onClick={toggleLocale} style={{
                    background: 'rgba(255,255,255,0.1)', border: 'none', color: 'rgba(255,255,255,0.8)',
                    padding: '6px 12px', borderRadius: 6, cursor: 'pointer', display: 'flex',
                    alignItems: 'center', gap: 4, fontSize: 12,
                }}>
                    <LuGlobe size={14} /> {locale === 'ja' ? 'EN' : 'JA'}
                </button>
            </header>

            <div style={{ display: 'flex', maxWidth: 1280, margin: '0 auto' }}>
                {/* Sidebar Stepper */}
                <div style={{ width: 260, background: 'white', minHeight: 'calc(100vh - 56px)', borderRight: '1px solid var(--border)', paddingTop: 24 }}>
                    {steps.map((label, i) => {
                        const isClickable = i <= step && i < 2;
                        return (
                            <div
                                key={i}
                                className={`stepper-item ${i === step ? 'active' : ''} ${i < step ? 'completed' : ''}`}
                                onClick={() => isClickable && setStep(i)}
                                style={{ cursor: isClickable ? 'pointer' : 'default', opacity: i > step ? 0.4 : 1 }}
                            >
                                <div className="stepper-circle">
                                    {i < step ? <LuCheck size={14} /> : i + 1}
                                </div>
                                <span style={{ fontSize: 14, fontWeight: i === step ? 600 : 400, color: i === step ? 'var(--primary)' : 'var(--text-secondary)' }}>
                                    {label}
                                </span>
                            </div>
                        )
                    })}
                </div>

                {/* Content */}
                <div style={{ flex: 1, padding: 32 }}>
                    <div className="animate-fade-in">
                        {step === 0 && (
                            <div>
                                <h2 style={{ fontSize: 22, fontWeight: 700, color: 'var(--primary-dark)', marginBottom: 8 }}>
                                    {t('basicInfo')}
                                </h2>
                                <p style={{ fontSize: 14, color: 'var(--text-secondary)', marginBottom: 32 }}>
                                    {locale === 'ja' ? '案件の基本情報を入力してください' : 'Enter basic case information'}
                                </p>

                                {/* Customer Type */}
                                <div className="section-card">
                                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 16 }}>
                                        <LuUser size={18} color="var(--primary)" />
                                        <span style={{ fontWeight: 600 }}>{t('customerType')}</span>
                                        <span className="badge-required">{t('required')}</span>
                                    </div>
                                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                                        <div
                                            className={`radio-card ${customerType === 'individual' ? 'selected' : ''}`}
                                            onClick={() => setCustomerType('individual')}
                                        >
                                            <LuUser size={20} color={customerType === 'individual' ? 'var(--primary)' : '#999'} />
                                            <span style={{ fontWeight: customerType === 'individual' ? 600 : 400 }}>{t('individual')}</span>
                                        </div>
                                        <div
                                            className={`radio-card ${customerType === 'corporate' ? 'selected' : ''}`}
                                            onClick={() => setCustomerType('corporate')}
                                        >
                                            <LuBuilding size={20} color={customerType === 'corporate' ? 'var(--primary)' : '#999'} />
                                            <span style={{ fontWeight: customerType === 'corporate' ? 600 : 400 }}>{t('corporate')}</span>
                                        </div>
                                    </div>
                                </div>

                                {/* Customer Ref */}
                                <div className="section-card">
                                    <label className="form-label">
                                        {t('customerRef')} <span className="badge-required">{t('required')}</span>
                                    </label>
                                    <input
                                        className="form-input"
                                        value={customerRef}
                                        onChange={e => setCustomerRef(e.target.value)}
                                        placeholder="例: C-2026-0001"
                                    />
                                </div>

                                {/* Run Type */}
                                <div className="section-card">
                                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 16 }}>
                                        <span style={{ fontWeight: 600 }}>{t('runType')}</span>
                                        <span className="badge-required">{t('required')}</span>
                                    </div>
                                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                                        <div
                                            className={`radio-card ${runType === 'new_contract' ? 'selected' : ''}`}
                                            onClick={() => setRunType('new_contract')}
                                        >
                                            <LuFilePlus size={20} color={runType === 'new_contract' ? 'var(--primary)' : '#999'} />
                                            <span>{t('newContract')}</span>
                                        </div>
                                        <div
                                            className={`radio-card ${runType === 'renewal' ? 'selected' : ''}`}
                                            onClick={() => setRunType('renewal')}
                                        >
                                            <LuRefreshCw size={20} color={runType === 'renewal' ? 'var(--primary)' : '#999'} />
                                            <span>{t('renewal')}</span>
                                        </div>
                                    </div>
                                </div>

                                {/* KYC & Test */}
                                <div className="section-card">
                                    <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
                                        <input type="checkbox" id="kyc" checked={kycConfirmed}
                                            onChange={e => setKycConfirmed(e.target.checked)}
                                            style={{ width: 18, height: 18, accentColor: 'var(--primary)' }}
                                        />
                                        <label htmlFor="kyc" style={{ fontWeight: 500, cursor: 'pointer' }}>{t('kycConfirmed')}</label>
                                    </div>
                                    <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                                        <input type="checkbox" id="test" checked={isTest}
                                            onChange={e => setIsTest(e.target.checked)}
                                            style={{ width: 18, height: 18, accentColor: 'var(--warning)' }}
                                        />
                                        <label htmlFor="test" style={{ cursor: 'pointer' }}>
                                            <span style={{ fontWeight: 500 }}>{t('testData')}</span>
                                            <span style={{ fontSize: 12, color: 'var(--text-secondary)', marginLeft: 8 }}>
                                                {t('testDataNote')}
                                            </span>
                                        </label>
                                    </div>
                                </div>

                                {error && (
                                    <div style={{
                                        background: 'rgba(198,40,40,0.08)', color: 'var(--error)',
                                        padding: '10px 14px', borderRadius: 8, fontSize: 13, marginBottom: 16,
                                    }}>
                                        {error}
                                    </div>
                                )}

                                <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12, marginTop: 24 }}>
                                    <button className="btn-secondary" onClick={() => router.push('/dashboard')}>
                                        {t('cancel')}
                                    </button>
                                    <button className="btn-primary" onClick={() => {
                                        if (!customerRef.trim()) { setError(t('fieldRequired')); return; }
                                        setError('');
                                        setStep(1);
                                    }}>
                                        <LuChevronRight size={16} /> {t('next')}
                                    </button>
                                </div>
                            </div>
                        )}

                        {step === 1 && (
                            <div>
                                <h2 style={{ fontSize: 22, fontWeight: 700, color: 'var(--primary-dark)', marginBottom: 8 }}>
                                    {t('intentionConfirmation')}
                                </h2>
                                <p style={{ fontSize: 14, color: 'var(--text-secondary)', marginBottom: 32 }}>
                                    {runType === 'new_contract' ? t('step2NewTitle') : t('step2ExistTitle')}
                                </p>

                                {/* Decision options */}
                                <div className="section-card">
                                    <div style={{ fontWeight: 600, marginBottom: 16 }}>{t('step1Title')}</div>
                                    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                                        {(runType === 'new_contract'
                                            ? [
                                                { key: 'compare_requested', label: t('compareRequested') },
                                                { key: 'externally_designated', label: t('externallyDesignated') },
                                                { key: 'urgent_by_customer', label: t('urgentByCustomer') },
                                                { key: 'new_contract_minimum', label: t('newContractMinimum') },
                                                { key: 'information_refused', label: t('informationRefused') },
                                            ]
                                            : [
                                                { key: 'compare_requested', label: t('compareRequested') },
                                                { key: 'status_quo_selected', label: t('statusQuoSelected') },
                                                { key: 'delegated_to_agent', label: t('delegatedToAgent') },
                                                { key: 'renewal_no_change', label: t('renewalNoChange') },
                                                { key: 'externally_designated', label: t('externallyDesignated') },
                                            ]
                                        ).map(opt => (
                                            <div
                                                key={opt.key}
                                                className={`radio-card ${customerDecision === opt.key ? 'selected' : ''}`}
                                                onClick={() => setCustomerDecision(opt.key)}
                                            >
                                                <div style={{
                                                    width: 18, height: 18, borderRadius: '50%', border: `2px solid ${customerDecision === opt.key ? 'var(--primary)' : '#ccc'}`,
                                                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                                                }}>
                                                    {customerDecision === opt.key && <div style={{ width: 10, height: 10, borderRadius: '50%', background: 'var(--primary)' }} />}
                                                </div>
                                                <span>{opt.label}</span>
                                            </div>
                                        ))}
                                    </div>
                                </div>

                                {/* Confirmation Method */}
                                <div className="section-card">
                                    <label className="form-label">{t('intentionConfirmMethod')}</label>
                                    <select className="form-select" value={intentionMethod} onChange={e => setIntentionMethod(e.target.value)}>
                                        <option value="">---</option>
                                        <option value="face_to_face">{t('faceToFace')}</option>
                                        <option value="phone">{t('phone')}</option>
                                        <option value="written">{t('written')}</option>
                                        <option value="other">{t('otherMethod')}</option>
                                    </select>
                                </div>

                                {/* Priority Factors */}
                                <div className="section-card">
                                    <label className="form-label">{t('priorityFactors')}</label>
                                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
                                        {['premium', 'coverage', 'deductible', 'service', 'claimsHandling', 'paymentRecord'].map(f => (
                                            <button
                                                key={f}
                                                onClick={() => setPriorityFactors(prev =>
                                                    prev.includes(f) ? prev.filter(x => x !== f) : [...prev, f]
                                                )}
                                                style={{
                                                    padding: '6px 14px', borderRadius: 20, border: 'none', fontSize: 13,
                                                    cursor: 'pointer', fontWeight: 500,
                                                    background: priorityFactors.includes(f) ? 'var(--primary)' : '#e8eaf6',
                                                    color: priorityFactors.includes(f) ? 'white' : 'var(--primary)',
                                                }}
                                            >
                                                {t(f as 'premium')}
                                            </button>
                                        ))}
                                    </div>
                                </div>

                                {/* Summary */}
                                <div className="section-card">
                                    <label className="form-label">
                                        {t('intentionSummary')} <span className="badge-required">≥15{locale === 'ja' ? '文字' : ' chars'}</span>
                                    </label>
                                    <textarea
                                        className="form-input"
                                        rows={4}
                                        value={intentionSummary}
                                        onChange={e => setIntentionSummary(e.target.value)}
                                        placeholder={locale === 'ja' ? 'お客様の意向を要旨として記録してください（15文字以上）' : 'Record customer intention summary (15+ chars)'}
                                    />
                                    <div style={{ fontSize: 12, color: intentionSummary.length < 15 ? 'var(--error)' : 'var(--success)', marginTop: 4 }}>
                                        {intentionSummary.length} / 15 min
                                    </div>
                                </div>

                                <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12, marginTop: 24 }}>
                                    <button className="btn-secondary" onClick={() => setStep(0)}>
                                        {t('back')}
                                    </button>
                                    <button className="btn-primary" onClick={handleCreateRun} disabled={loading || !customerDecision || intentionSummary.length < 15}>
                                        {loading ? <span className="animate-pulse-soft">{t('loading')}</span> : (
                                            <><LuSave size={16} /> {locale === 'ja' ? '案件を保存して候補入力へ' : 'Save & Edit Candidates'}</>
                                        )}
                                    </button>
                                </div>
                            </div>
                        )}

                        {step === 2 && (
                            <div>
                                <h2 style={{ fontSize: 22, fontWeight: 700, color: 'var(--primary-dark)', marginBottom: 8 }}>
                                    {t('candidates')}
                                </h2>
                                <p style={{ fontSize: 14, color: 'var(--text-secondary)', marginBottom: 32 }}>
                                    {locale === 'ja' ? '案件を保存してから候補を追加してください' : 'Save the case first, then add candidates'}
                                </p>
                                <div className="section-card" style={{ textAlign: 'center', padding: 48 }}>
                                    <p style={{ color: 'var(--text-secondary)', marginBottom: 16 }}>
                                        {locale === 'ja' ? '案件を先に保存する必要があります' : 'Please save the case first'}
                                    </p>
                                    <button className="btn-primary" onClick={handleCreateRun} disabled={loading}>
                                        <LuSave size={16} /> {locale === 'ja' ? '案件を保存して候補入力へ' : 'Save & go to candidates'}
                                    </button>
                                </div>
                            </div>
                        )}

                        {step === 3 && (
                            <div>
                                <h2 style={{ fontSize: 22, fontWeight: 700, color: 'var(--primary-dark)', marginBottom: 8 }}>
                                    {t('finalize')}
                                </h2>
                                <div className="section-card" style={{ textAlign: 'center', padding: 48 }}>
                                    <p style={{ color: 'var(--text-secondary)' }}>
                                        {locale === 'ja' ? '案件を作成してから確定操作を行ってください' : 'Create the case first before finalizing'}
                                    </p>
                                </div>
                            </div>
                        )}
                    </div>
                </div>
            </div>
        </div>
    )
}
