'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import {
    Shield, Globe, ArrowLeft, Check,
    User, Building, FilePlus, RefreshCw,
    Zap, Clock, Monitor, Smartphone, UserCog,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import Step1Diagnosis, { type Step1Data } from './_steps/Step1Diagnosis'
import Step2IssueSharing from './_steps/Step2IssueSharing'
import Step3Intent, { type Step3Data } from './_steps/Step3Intent'
import Step4Scope, { type Step4Data } from './_steps/Step4Scope'
import Step5Priority, { type Step5Data } from './_steps/Step5Priority'
import type { CustomerType, RunType, CustomerDecision, AuditEventInsert, RecordingMode, InputDevice, MeetingScene } from '@/lib/types'
import { MEETING_SCENE_CONFIG } from '@/lib/types'

// ─────────────────────────────────────────────
// Wizard step definitions
// ─────────────────────────────────────────────
const STEPS = [
    { num: 1, labelJa: '診断', labelEn: 'Diagnosis' },
    { num: 2, labelJa: '課題共有', labelEn: 'Issue Sharing' },
    { num: 3, labelJa: '顧客意向', labelEn: 'Intent' },
    { num: 4, labelJa: '比較範囲', labelEn: 'Scope' },
    { num: 5, labelJa: '重視事項', labelEn: 'Priority' },
]

export default function NewRunPage() {
    const router = useRouter()
    const { locale, toggleLocale } = useLocale()

    // ── Customer basics (collected before Step 1) ──
    const [customerType, setCustomerType] = useState<CustomerType>('individual')
    const [customerRef, setCustomerRef] = useState('')
    const [customerName, setCustomerName] = useState('')           // G-2
    const [corporateDecisionMaker, setCorporateDecisionMaker] = useState('')  // G-3
    const [runType, setRunType] = useState<RunType>('new_contract')
    const [isTest, setIsTest] = useState(false)
    // G-20 / G-23: 2-axis recording mode + device selection
    const [recordingMode, setRecordingMode] = useState<RecordingMode>('realtime')
    const [inputDevice, setInputDevice] = useState<InputDevice>('tablet_pc')
    // G-28: 面談シーンプリセット
    const [meetingScene, setMeetingScene] = useState<MeetingScene | ''>('')
    const [basicsError, setBasicsError] = useState('')
    const [basicsComplete, setBasicsComplete] = useState(false)

    // ── Wizard state ──
    const [step, setStep] = useState<1 | 2 | 3 | 4 | 5>(1)

    // ── Per-step collected data ──
    const [step1Data, setStep1Data] = useState<Step1Data | null>(null)
    const [diagnosisMemo, setDiagnosisMemo] = useState('')
    const [step3Data, setStep3Data] = useState<Step3Data | null>(null)
    const [step4Data, setStep4Data] = useState<Step4Data | null>(null)

    // ── Async state ──
    const [submitting, setSubmitting] = useState(false)
    const [submitError, setSubmitError] = useState('')

    // ─────────────────────────────────────────────
    // Basics confirmation
    // ─────────────────────────────────────────────
    const confirmBasics = () => {
        if (!customerRef.trim()) {
            setBasicsError(locale === 'ja' ? '顧客参照IDを入力してください' : 'Please enter a customer reference')
            return
        }
        setBasicsError('')
        setBasicsComplete(true)
    }

    // ─────────────────────────────────────────────
    // Step handlers
    // ─────────────────────────────────────────────
    const handleStep1Complete = (data: Step1Data) => {
        setStep1Data(data)
        setStep(2)
    }

    const handleStep2Complete = (memo: string) => {
        setDiagnosisMemo(memo)
        setStep(3)
    }

    const handleStep3Complete = async (data: Step3Data) => {
        setStep3Data(data)
        // DB writes happen here
        await createRunAndFireEvents(data)
    }

    const handleStep4Complete = async (data: Step4Data) => {
        setStep4Data(data)
        // UPDATE run with scope data
        await updateRunScope(data)
    }

    const handleStep5Complete = async (data: Step5Data) => {
        // UPDATE run with priority data then navigate to comparison
        await updateRunPriority(data)
    }

    // ─────────────────────────────────────────────
    // createRunAndFireEvents — called at Step3 completion
    // Batch: INSERT run + snapshot + 4 audit events
    // ─────────────────────────────────────────────
    const createRunAndFireEvents = async (intentData: Step3Data) => {
        if (!step1Data) return
        setSubmitting(true)
        setSubmitError('')

        try {
            const supabase = createClient()
            const { data: { user } } = await supabase.auth.getUser()
            if (!user) throw new Error('Not authenticated')

            const { data: op, error: opErr } = await supabase
                .from('operator')
                .select('*')
                .eq('auth_user_id', user.id)
                .single()
            if (opErr || !op) throw new Error('Operator not found')

            // ── 1. INSERT run ──
            const { data: run, error: runErr } = await supabase.from('run').insert({
                agency_id: op.agency_id,
                operator_id: op.id,
                product_line: 'auto',           // legacy field — kept for DB compat
                insurance_category_code: 'auto', // b0-MS1: 種目選択UI実装まで固定
                insurance_line_code: 'auto',     // b0-MS1: 種目選択UI実装まで固定
                customer_type: customerType,
                customer_ref: customerRef.trim(),
                customer_name: customerName.trim() || null,
                corporate_decision_maker: customerType === 'corporate' ? (corporateDecisionMaker.trim() || null) : null,
                run_type: runType,
                is_test: isTest,
                core_logic_version: '1.0.0',
                customer_decision: intentData.customerDecision,
                customer_decision_at: new Date().toISOString(),
                customer_intent_memo: intentData.customerIntentMemo,
                intent_confirmed_with: intentData.intentConfirmedWith || null,
                diagnosis_memo: diagnosisMemo,
                condition_change_note: step1Data.conditionChangeNote || null,
                recording_mode: recordingMode,
                input_device: inputDevice,
                meeting_scene: meetingScene || null,
                run_status: 'draft',
                export_status: 'pending',
            }).select().single()
            if (runErr || !run) throw runErr ?? new Error('Run insert failed')

            const runId: string = run.id

            // ── 2. INSERT snapshot ──
            const { error: snapErr } = await supabase.from('snapshot').insert({
                run_id: runId,
                csv_imported: step1Data.csvImported,
                pdf_object_key: step1Data.pdfObjectKey || null,
                missing_flags: step1Data.missingFlags,
                uncertain_flags: step1Data.uncertainFlags,
                confirmed_items: step1Data.confirmedItems,
                supplemented_items: step1Data.supplementedItems,
                unresolved_items: step1Data.unresolvedItems,
                reviewed_at: new Date().toISOString(),
                reviewed_by: op.id,
                core_logic_version: '1.0.0',
            })
            if (snapErr) throw snapErr

            // ── 3–6. Batch INSERT audit events ──
            const events: AuditEventInsert[] = [
                {
                    run_id: runId,
                    event_type: 'manual_review_completed' as const,
                    operator_id: op.id,
                    payload: {
                        confirmed_items: step1Data.confirmedItems,
                        supplemented_items: step1Data.supplementedItems,
                        unresolved_items: step1Data.unresolvedItems,
                    },
                },
                {
                    run_id: runId,
                    event_type: 'issue_shared' as const,
                    operator_id: op.id,
                    payload: { diagnosis_memo: diagnosisMemo },
                },
                {
                    run_id: runId,
                    event_type: 'customer_intent_confirmed' as const,
                    operator_id: op.id,
                    payload: {
                        decision: intentData.customerDecision,
                        memo: intentData.customerIntentMemo,
                    },
                },
            ]

            // G-20/G-23: recording mode selected — always fires
            events.push({
                run_id: runId,
                event_type: 'recording_mode_selected' as const,
                operator_id: op.id,
                payload: { recording_mode: recordingMode, input_device: inputDevice },
            })
            // G-28: meeting scene selected — fires when scene is chosen
            if (meetingScene) {
                events.push({
                    run_id: runId,
                    event_type: 'meeting_scene_selected' as const,
                    operator_id: op.id,
                    payload: { scene: meetingScene, config: MEETING_SCENE_CONFIG[meetingScene] },
                })
            }
            // G-23: agent_input_mode_activated — fires when agent_smartphone selected
            if (inputDevice === 'agent_smartphone') {
                events.push({
                    run_id: runId,
                    event_type: 'agent_input_mode_activated' as const,
                    operator_id: op.id,
                    payload: { input_device: inputDevice },
                })
            }

            // comparison_waiver_confirmed event for comparison_waived path
            if (intentData.customerDecision === 'comparison_waived') {
                events.push({
                    run_id: runId,
                    event_type: 'comparison_waiver_confirmed' as const,
                    operator_id: op.id,
                    payload: {
                        consent_important_matters: intentData.consentState.importantMatters,
                        consent_personal_info: intentData.consentState.personalInfo,
                    },
                })
            }

            const { error: eventsErr } = await supabase.from('audit_event').insert(events)
            if (eventsErr) throw eventsErr

            // b1-MS1 #48 (2026-08-01): insurer_list_presented is a finalize_run
            // precondition, so it can no longer be recorded via direct insert
            // (migration 039 blocks that at the DB level). Record it through
            // its dedicated RPC instead.
            const { error: insurerListErr } = await supabase.rpc('record_insurer_list_presented', { p_run_id: runId })
            if (insurerListErr) throw insurerListErr

            // ── Branch on customer decision ──
            const decision: CustomerDecision = intentData.customerDecision

            if (decision === 'compare') {
                // Normal path → continue to Step 4
                setStep3Data(intentData)
                setStep(4)
                // Store runId for Steps 4+5
                sessionStorage.setItem('wip_run_id', runId)
                sessionStorage.setItem('wip_op_id', op.id)
            } else {
                // Exception routes → finalize immediately
                const consentFlags = {
                    comparison_result: false,
                    important_matters: intentData.consentState.importantMatters,
                    personal_info: intentData.consentState.personalInfo,
                }
                const res = await fetch('/api/finalize', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        runId,
                        operatorId: op.id,
                        consentFlags,
                        exceptionRoute: true,
                    }),
                })
                if (!res.ok) {
                    const body = await res.json()
                    throw new Error(body.error ?? 'Finalize failed')
                }
                router.push(`/run/${runId}`)
            }
        } catch (err: unknown) {
            setSubmitError(err instanceof Error ? err.message : 'An error occurred')
        } finally {
            setSubmitting(false)
        }
    }

    // ─────────────────────────────────────────────
    // updateRunScope — called at Step4 completion
    // ─────────────────────────────────────────────
    const updateRunScope = async (data: Step4Data) => {
        const runId = sessionStorage.getItem('wip_run_id')
        if (!runId) return
        setSubmitting(true)
        setSubmitError('')
        try {
            const supabase = createClient()
            const { error } = await supabase.from('run').update({
                comparison_scope: data.comparisonScope,
                comparison_scope_memo: data.comparisonScopeMemo || null,
            }).eq('id', runId)
            if (error) throw error
            setStep4Data(data)
            setStep(5)
        } catch (err: unknown) {
            setSubmitError(err instanceof Error ? err.message : 'An error occurred')
        } finally {
            setSubmitting(false)
        }
    }

    // ─────────────────────────────────────────────
    // updateRunPriority — called at Step5 completion
    // ─────────────────────────────────────────────
    const updateRunPriority = async (data: Step5Data) => {
        const runId = sessionStorage.getItem('wip_run_id')
        if (!runId) return
        setSubmitting(true)
        setSubmitError('')
        try {
            const supabase = createClient()
            const { error } = await supabase.from('run').update({
                priority_factors: data.priorityFactors,
                priority_weight: data.priorityWeight,
            }).eq('id', runId)
            if (error) throw error
            router.push(`/run/${runId}?tab=comparison`)
        } catch (err: unknown) {
            setSubmitError(err instanceof Error ? err.message : 'An error occurred')
        } finally {
            setSubmitting(false)
        }
    }

    // ─────────────────────────────────────────────
    // Sidebar step label helper
    // ─────────────────────────────────────────────
    const isStepDimmed = (stepNum: number) => {
        // Steps 4-5 are dimmed when decision is non-compare (or not yet selected)
        if (stepNum >= 4) {
            if (!step3Data) return true
            if (step3Data.customerDecision !== 'compare') return true
        }
        return false
    }

    // ─────────────────────────────────────────────
    // Render
    // ─────────────────────────────────────────────
    return (
        <div className="min-h-screen bg-gray-50">
            {/* Header */}
            <header className="bg-blue-700 text-white h-14 flex items-center justify-between px-6 shadow-md">
                <div className="flex items-center gap-3">
                    <button
                        onClick={() => router.push('/dashboard')}
                        className="bg-white/10 hover:bg-white/20 border-0 text-white p-2 rounded cursor-pointer"
                    >
                        <ArrowLeft size={18} />
                    </button>
                    <Shield size={18} />
                    <span className="font-semibold">
                        {locale === 'ja' ? '新規案件' : 'New Run'}
                    </span>
                </div>
                <button
                    onClick={toggleLocale}
                    className="bg-white/10 hover:bg-white/20 border-0 text-white/80 px-3 py-1.5 rounded text-xs flex items-center gap-1 cursor-pointer"
                >
                    <Globe size={14} />
                    {locale === 'ja' ? 'EN' : 'JA'}
                </button>
            </header>

            <div className="flex max-w-5xl mx-auto">
                {/* Sidebar Stepper */}
                <div className="w-56 bg-white min-h-[calc(100vh-56px)] border-r border-gray-200 pt-6 shrink-0">
                    {STEPS.map(({ num, labelJa, labelEn }) => {
                        const completed = step > num
                        const active = step === num
                        const dimmed = isStepDimmed(num)
                        return (
                            <div
                                key={num}
                                className={`flex items-center gap-3 px-4 py-3 ${dimmed ? 'opacity-35' : ''}`}
                            >
                                <div
                                    className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold shrink-0 ${
                                        completed
                                            ? 'bg-green-500 text-white'
                                            : active
                                            ? 'bg-blue-600 text-white'
                                            : 'bg-gray-200 text-gray-500'
                                    }`}
                                >
                                    {completed ? <Check size={13} /> : num}
                                </div>
                                <span
                                    className={`text-sm ${
                                        active ? 'font-semibold text-blue-700' : 'text-gray-500'
                                    }`}
                                >
                                    {locale === 'ja' ? labelJa : labelEn}
                                </span>
                            </div>
                        )
                    })}
                </div>

                {/* Main content */}
                <div className="flex-1 p-8">
                    {/* Customer basics — shown above Step 1 if not confirmed */}
                    {!basicsComplete && (
                        <div className="space-y-5 mb-8 p-6 bg-white rounded-xl border border-gray-200 shadow-sm">
                            <h2 className="text-base font-semibold text-gray-800">
                                {locale === 'ja' ? '基本情報' : 'Basic Information'}
                            </h2>

                            {/* Customer type */}
                            <div>
                                <label className="form-label">
                                    {locale === 'ja' ? '顧客種別' : 'Customer Type'}
                                    <span className="badge-required">
                                        {locale === 'ja' ? '必須' : 'Required'}
                                    </span>
                                </label>
                                <div className="grid grid-cols-2 gap-3 mt-2">
                                    {(
                                        [
                                            { value: 'individual', icon: User, labelJa: '個人', labelEn: 'Individual' },
                                            { value: 'corporate', icon: Building, labelJa: '法人', labelEn: 'Corporate' },
                                        ] as const
                                    ).map(({ value, icon: Icon, labelJa, labelEn }) => (
                                        <label
                                            key={value}
                                            className={`radio-card cursor-pointer flex items-center gap-2 ${
                                                customerType === value ? 'ring-2 ring-blue-500' : ''
                                            }`}
                                        >
                                            <input
                                                type="radio"
                                                name="customerType"
                                                value={value}
                                                checked={customerType === value}
                                                onChange={() => setCustomerType(value)}
                                                className="sr-only"
                                            />
                                            <Icon size={18} className={customerType === value ? 'text-blue-600' : 'text-gray-400'} />
                                            <span className="text-sm font-medium">
                                                {locale === 'ja' ? labelJa : labelEn}
                                            </span>
                                        </label>
                                    ))}
                                </div>
                            </div>

                            {/* Customer ref */}
                            <div>
                                <label className="form-label">
                                    {locale === 'ja' ? '顧客参照ID' : 'Customer Reference'}
                                    <span className="badge-required">
                                        {locale === 'ja' ? '必須' : 'Required'}
                                    </span>
                                </label>
                                <input
                                    type="text"
                                    value={customerRef}
                                    onChange={(e) => { setCustomerRef(e.target.value); setBasicsError('') }}
                                    placeholder={locale === 'ja' ? '例: C-2026-0001' : 'e.g. C-2026-0001'}
                                    className="form-input"
                                />
                            </div>

                            {/* G-2: 顧客名 */}
                            <div>
                                <label className="form-label">
                                    {locale === 'ja' ? '顧客名' : 'Customer Name'}
                                </label>
                                <input
                                    type="text"
                                    value={customerName}
                                    onChange={e => setCustomerName(e.target.value)}
                                    placeholder={locale === 'ja' ? '例: 山田 太郎' : 'e.g. Taro Yamada'}
                                    className="form-input"
                                />
                            </div>

                            {/* G-3: 法人意思決定者（法人のみ） */}
                            {customerType === 'corporate' && (
                                <div>
                                    <label className="form-label">
                                        {locale === 'ja' ? '法人意思決定者' : 'Corporate Decision Maker'}
                                    </label>
                                    <input
                                        type="text"
                                        value={corporateDecisionMaker}
                                        onChange={e => setCorporateDecisionMaker(e.target.value)}
                                        placeholder={locale === 'ja' ? '例: 代表取締役 田中一郎' : 'e.g. CEO Ichiro Tanaka'}
                                        className="form-input"
                                    />
                                </div>
                            )}

                            {/* Run type */}
                            <div>
                                <label className="form-label">
                                    {locale === 'ja' ? '案件種別' : 'Run Type'}
                                    <span className="badge-required">
                                        {locale === 'ja' ? '必須' : 'Required'}
                                    </span>
                                </label>
                                <div className="grid grid-cols-2 gap-3 mt-2">
                                    {(
                                        [
                                            { value: 'new_contract', icon: FilePlus, labelJa: '新規契約', labelEn: 'New Contract' },
                                            { value: 'renewal', icon: RefreshCw, labelJa: '更新', labelEn: 'Renewal' },
                                        ] as const
                                    ).map(({ value, icon: Icon, labelJa, labelEn }) => (
                                        <label
                                            key={value}
                                            className={`radio-card cursor-pointer flex items-center gap-2 ${
                                                runType === value ? 'ring-2 ring-blue-500' : ''
                                            }`}
                                        >
                                            <input
                                                type="radio"
                                                name="runType"
                                                value={value}
                                                checked={runType === value}
                                                onChange={() => setRunType(value)}
                                                className="sr-only"
                                            />
                                            <Icon size={18} className={runType === value ? 'text-blue-600' : 'text-gray-400'} />
                                            <span className="text-sm font-medium">
                                                {locale === 'ja' ? labelJa : labelEn}
                                            </span>
                                        </label>
                                    ))}
                                </div>
                            </div>

                            {/* G-20: 記録方式 */}
                            <div>
                                <label className="form-label">
                                    {locale === 'ja' ? '記録方式' : 'Recording Mode'}
                                    <span className="badge-required">
                                        {locale === 'ja' ? '必須' : 'Required'}
                                    </span>
                                </label>
                                <div className="grid grid-cols-2 gap-3 mt-2">
                                    {(
                                        [
                                            { value: 'realtime' as RecordingMode, icon: Zap, labelJa: 'リアルタイム記録', labelEn: 'Real-time', descJa: '面談中にその場で入力', descEn: 'Enter during the meeting' },
                                            { value: 'post_record' as RecordingMode, icon: Clock, labelJa: '事後記録', labelEn: 'Post-record', descJa: '面談後に後日入力', descEn: 'Enter after the meeting' },
                                        ]
                                    ).map(({ value, icon: Icon, labelJa, labelEn, descJa, descEn }) => (
                                        <label
                                            key={value}
                                            className={`radio-card cursor-pointer flex flex-col gap-1 ${recordingMode === value ? 'ring-2 ring-blue-500' : ''}`}
                                        >
                                            <input
                                                type="radio"
                                                name="recordingMode"
                                                value={value}
                                                checked={recordingMode === value}
                                                onChange={() => setRecordingMode(value)}
                                                className="sr-only"
                                            />
                                            <div className="flex items-center gap-2">
                                                <Icon size={16} className={recordingMode === value ? 'text-blue-600' : 'text-gray-400'} />
                                                <span className="text-sm font-medium">{locale === 'ja' ? labelJa : labelEn}</span>
                                            </div>
                                            <span className="text-xs text-gray-500">{locale === 'ja' ? descJa : descEn}</span>
                                        </label>
                                    ))}
                                </div>
                            </div>

                            {/* G-23: 入力デバイス */}
                            <div>
                                <label className="form-label">
                                    {locale === 'ja' ? '入力デバイス' : 'Input Device'}
                                    <span className="badge-required">
                                        {locale === 'ja' ? '必須' : 'Required'}
                                    </span>
                                </label>
                                <div className="grid grid-cols-3 gap-3 mt-2">
                                    {(
                                        [
                                            { value: 'tablet_pc' as InputDevice, icon: Monitor, labelJa: 'タブレット/PC', labelEn: 'Tablet/PC' },
                                            { value: 'customer_smartphone' as InputDevice, icon: Smartphone, labelJa: 'お客様スマホ', labelEn: 'Customer Phone' },
                                            { value: 'agent_smartphone' as InputDevice, icon: UserCog, labelJa: '募集人スマホ', labelEn: 'Agent Phone' },
                                        ]
                                    ).map(({ value, icon: Icon, labelJa, labelEn }) => (
                                        <label
                                            key={value}
                                            className={`radio-card cursor-pointer flex items-center gap-2 ${inputDevice === value ? 'ring-2 ring-blue-500' : ''}`}
                                        >
                                            <input
                                                type="radio"
                                                name="inputDevice"
                                                value={value}
                                                checked={inputDevice === value}
                                                onChange={() => setInputDevice(value)}
                                                className="sr-only"
                                            />
                                            <Icon size={16} className={inputDevice === value ? 'text-blue-600' : 'text-gray-400'} />
                                            <span className="text-sm font-medium">{locale === 'ja' ? labelJa : labelEn}</span>
                                        </label>
                                    ))}
                                </div>
                                {inputDevice === 'agent_smartphone' && (
                                    <p className="text-xs text-amber-600 mt-2">
                                        {locale === 'ja'
                                            ? '※ 募集人が代行入力します。確認文言が「説明しました」形式に切り替わります。'
                                            : '※ Agent enters on behalf of customer. Confirmation wording switches to agent-input format.'}
                                    </p>
                                )}
                            </div>

                            {/* G-28: 面談シーンプリセット */}
                            <div>
                                <label className="form-label">
                                    {locale === 'ja' ? '面談シーン（G-28）' : 'Meeting Scene (G-28)'}
                                </label>
                                <div className="grid grid-cols-1 gap-2 mt-2">
                                    {(
                                        [
                                            { value: 'visit_smartphone' as MeetingScene, labelJa: '訪問・スマホ連携', labelEn: 'Visit + Smartphone', descJa: '訪問面談、お客様スマホで確認', descEn: 'In-person visit, customer confirms on phone' },
                                            { value: 'visit_paper' as MeetingScene, labelJa: '訪問・ペーパー確認', labelEn: 'Visit + Paper', descJa: '訪問面談、紙面で確認・募集人入力', descEn: 'In-person visit, paper confirmation' },
                                            { value: 'pc_tablet' as MeetingScene, labelJa: 'PC・タブレット型', labelEn: 'PC/Tablet', descJa: 'PC/タブレットで電子同意', descEn: 'Electronic consent via PC/tablet' },
                                            { value: 'telephone' as MeetingScene, labelJa: '電話募集型', labelEn: 'Telephone', descJa: '電話で面談、募集人入力', descEn: 'Telephone meeting, agent input' },
                                            { value: 'web_meeting' as MeetingScene, labelJa: 'WEB面談', labelEn: 'Web Meeting', descJa: 'オンライン面談、電子同意', descEn: 'Online meeting, electronic consent' },
                                        ]
                                    ).map(({ value, labelJa, labelEn, descJa, descEn }) => (
                                        <label
                                            key={value}
                                            className={`radio-card cursor-pointer flex items-center justify-between gap-2 ${meetingScene === value ? 'ring-2 ring-blue-500' : ''}`}
                                        >
                                            <input
                                                type="radio"
                                                name="meetingScene"
                                                value={value}
                                                checked={meetingScene === value}
                                                onChange={() => setMeetingScene(value)}
                                                className="sr-only"
                                            />
                                            <div>
                                                <span className="text-sm font-medium">{locale === 'ja' ? labelJa : labelEn}</span>
                                                <span className="block text-xs text-gray-400">{locale === 'ja' ? descJa : descEn}</span>
                                            </div>
                                            {meetingScene === value && <span className="text-blue-600 text-xs font-bold">✓</span>}
                                        </label>
                                    ))}
                                </div>
                                <p className="text-xs text-gray-400 mt-1">
                                    {locale === 'ja' ? '※ 未選択の場合はPhase1フローで処理されます' : '※ If not selected, Phase1 flow will be used'}
                                </p>
                            </div>

                            {/* Test flag */}
                            <label className="flex items-center gap-3 cursor-pointer">
                                <input
                                    type="checkbox"
                                    checked={isTest}
                                    onChange={(e) => setIsTest(e.target.checked)}
                                    className="w-4 h-4 rounded"
                                />
                                <span className="text-sm text-gray-700">
                                    {locale === 'ja' ? 'テストデータ（本番集計に含まれません）' : 'Test data (excluded from production stats)'}
                                </span>
                            </label>

                            {basicsError && <p className="form-error">{basicsError}</p>}

                            <button
                                type="button"
                                onClick={confirmBasics}
                                className="btn-primary w-full"
                            >
                                {locale === 'ja' ? '基本情報を確定して診断へ' : 'Confirm & Start Diagnosis'}
                            </button>
                        </div>
                    )}

                    {/* Step content — only rendered after basics are confirmed */}
                    {basicsComplete && (
                        <div>
                            {submitError && (
                                <div className="mb-4 px-4 py-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">
                                    {submitError}
                                </div>
                            )}

                            {submitting && (
                                <div className="mb-4 px-4 py-3 bg-blue-50 border border-blue-200 rounded-lg text-sm text-blue-700">
                                    {locale === 'ja' ? '保存中...' : 'Saving...'}
                                </div>
                            )}

                            {step === 1 && (
                                <Step1Diagnosis locale={locale} runType={runType} onComplete={handleStep1Complete} />
                            )}
                            {step === 2 && step1Data && (
                                <Step2IssueSharing
                                    locale={locale}
                                    missingFlags={step1Data.missingFlags}
                                    uncertainFlags={step1Data.uncertainFlags}
                                    onComplete={handleStep2Complete}
                                />
                            )}
                            {step === 3 && (
                                <Step3Intent
                                    locale={locale}
                                    runType={runType}
                                    onComplete={handleStep3Complete}
                                />
                            )}
                            {step === 4 && (
                                <Step4Scope locale={locale} onComplete={handleStep4Complete} />
                            )}
                            {step === 5 && (
                                <Step5Priority locale={locale} onComplete={handleStep5Complete} />
                            )}
                        </div>
                    )}
                </div>
            </div>
        </div>
    )
}
