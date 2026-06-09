import { createServerSupabaseClient } from '@/lib/supabase/server'

// GET /api/run/[id]/report-data
// Returns structured data for generating agency copy and customer sheet
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    try {
        const { id: runId } = await params
        const supabase = await createServerSupabaseClient()

        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 })

        const { data: run, error: runErr } = await supabase
            .from('run').select('*').eq('id', runId).single()
        if (runErr || !run) return Response.json({ error: 'run not found' }, { status: 404 })

        const { data: candidates } = await supabase
            .from('candidate').select('*').eq('run_id', runId).order('slot_no')

        const { data: auditEvents } = await supabase
            .from('audit_event').select('*').eq('run_id', runId).order('occurred_at', { ascending: true })

        const { data: snapshot } = await supabase
            .from('snapshot').select('*').eq('run_id', runId).maybeSingle()

        const { data: operator } = await supabase
            .from('operator').select('*').eq('id', run.operator_id).maybeSingle()

        // Resolve 3-axis candidates
        const candidateMap = Object.fromEntries((candidates || []).map(c => [c.id, c]))
        const priorCandidate = (candidates || []).find(c => c.role === 'prior' || c.role === 'current')
        const recommendedCandidate = run.recommended_candidate_id
            ? candidateMap[run.recommended_candidate_id]
            : (candidates || []).find(c => c.role === 'recommended_1' || c.role === 'recommended')
        const decidedCandidate = run.decided_candidate_id
            ? candidateMap[run.decided_candidate_id]
            : null

        // Business quality checks (D-8: 10 items)
        const qualityChecks = computeQualityChecks(run, candidates || [], auditEvents || [], snapshot)

        // Categorized audit timeline (D-7)
        const timeline = buildTimeline(auditEvents || [])

        return Response.json({
            run,
            operator,
            candidates: candidates || [],
            snapshot,
            auditEvents: auditEvents || [],
            // 3-axis
            priorCandidate,
            recommendedCandidate,
            decidedCandidate,
            planDiffExists: recommendedCandidate && decidedCandidate
                ? recommendedCandidate.id !== decidedCandidate.id
                : false,
            planDiffReasonRecorded: !!run.plan_diff_reason,
            // D-7
            timeline,
            // D-8
            qualityChecks,
        })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}

// ── D-8: 業務品質チェック 10項目 ────────────────────────────────────────────
function computeQualityChecks(
    run: Record<string, unknown>,
    candidates: Record<string, unknown>[],
    auditEvents: Record<string, unknown>[],
    snapshot: Record<string, unknown> | null
) {
    const evtTypes = new Set(auditEvents.map(e => e.event_type as string))

    return [
        {
            id: 'current_contract_confirmed',
            label: '現契約の確認',
            pass: candidates.some(c => c.role === 'prior' || c.role === 'current'),
            note: '前年・現在契約の候補が登録されている',
        },
        {
            id: 'issue_shared',
            label: '課題共有',
            pass: evtTypes.has('issue_shared'),
            note: '診断結果・課題共有イベントが記録されている',
        },
        {
            id: 'intent_confirmed',
            label: '意向把握',
            pass: !!run.customer_decision,
            note: '顧客判断が記録されている',
        },
        {
            id: 'comparison_done',
            label: '比較表の提示',
            pass: !!run.compare_presented_at,
            note: '比較提示が記録されている',
        },
        {
            id: 'recommendation_reason',
            label: 'ご案内理由の記録',
            pass: !!run.recommended_candidate_id,
            note: '推奨プランが設定されている',
        },
        {
            id: 'customer_selection',
            label: 'お客様選択の記録',
            pass: !!run.decided_candidate_id,
            note: 'お客様決定プランが設定されている',
        },
        {
            id: 'redundancy_check',
            label: '補償重複確認',
            pass: Array.isArray(snapshot?.redundancy_decisions)
                ? (snapshot.redundancy_decisions as unknown[]).length > 0 || evtTypes.has('redundancy_resolution_recorded')
                : false,
            note: '補償重複確認が記録されている（または該当なし）',
        },
        {
            id: 'important_matters',
            label: '重要事項説明書の交付確認',
            pass: !!run.important_matters_delivered,
            note: '重要事項説明書交付確認が完了している',
        },
        {
            id: 'customer_confirmation',
            label: 'お客様確認',
            pass: !!run.customer_smartphone_confirmed_at || run.paper_confirmation_status === 'completed',
            note: 'お客様スマホ確認または紙面確認が完了している',
        },
        {
            id: 'record_timing',
            label: '記録時点の適切性',
            pass: !!run.finalized_at || run.run_status === 'post_record_pending',
            note: '確定または事後記録モードで記録されている',
        },
    ]
}

// ── D-7: 監査用タイムライン ─────────────────────────────────────────────────
const EVENT_CATEGORY: Record<string, string> = {
    'run_finalized':                    '確定',
    'compare_presented':                '比較・案内',
    'issue_shared':                     '現状確認',
    'manual_review_completed':          '現状確認',
    'insurer_list_presented':           '現状確認',
    'customer_intent_confirmed':        '意向把握',
    'exclusion_reason_recorded':        '比較・案内',
    'exclusion_reason_coded':           '比較・案内',
    'comparison_waiver_confirmed':      '比較・案内',
    'recommended_plan_set':             '比較・案内',
    'decided_plan_set':                 '比較・案内',
    'plan_diff_reason_recorded':        '比較・案内',
    'consent_important_matters':        '最終確認',
    'consent_personal_info':            '最終確認',
    'consent_comparison_result':        '最終確認',
    'delivery_recorded':                '最終確認',
    'important_matters_delivery_confirmed': '最終確認',
    'meeting_scene_selected':           '記録',
    'electronic_consent_recorded':      '記録',
    'recruiter_smartphone_confirmed':   '最終確認',
    'customer_smartphone_confirmed':    '最終確認',
    'paper_confirmation_completed':     '最終確認',
    'recording_mode_selected':          '記録',
    'post_record_phase1_completed':     '記録',
    'post_record_phase2_completed':     '記録',
    'agent_input_mode_activated':       '記録',
    'redundancy_resolution_recorded':   '比較・案内',
    'agency_report_generated':          '記録',
}

const EVENT_LABEL_JA: Record<string, string> = {
    'run_finalized':                    '案件確定',
    'compare_presented':                '比較表提示',
    'issue_shared':                     '課題共有',
    'manual_review_completed':          'マニュアルレビュー完了',
    'insurer_list_presented':           '取扱保険会社案内',
    'customer_intent_confirmed':        '意向確認',
    'exclusion_reason_recorded':        '除外理由記録',
    'exclusion_reason_coded':           '除外理由コード選択',
    'comparison_waiver_confirmed':      '比較免除確認',
    'recommended_plan_set':             '推奨プラン設定',
    'decided_plan_set':                 '決定プラン設定',
    'plan_diff_reason_recorded':        '差異理由記録',
    'consent_important_matters':        '重要事項同意',
    'consent_personal_info':            '個人情報同意',
    'consent_comparison_result':        '比較結果同意',
    'delivery_recorded':                '交付記録',
    'important_matters_delivery_confirmed': '重要事項説明書交付確認',
    'meeting_scene_selected':           '面談シーン選択',
    'electronic_consent_recorded':      '電子同意確認記録',
    'recruiter_smartphone_confirmed':   '募集人スマホ確認完了',
    'customer_smartphone_confirmed':    'お客様スマホ確認完了',
    'paper_confirmation_completed':     '紙面確認完了',
    'recording_mode_selected':          '記録方式選択',
    'post_record_phase1_completed':     '事後記録フェーズ1完了',
    'post_record_phase2_completed':     '事後記録フェーズ2完了',
    'agent_input_mode_activated':       '募集人入力モード起動',
    'redundancy_resolution_recorded':   '補償重複判定記録',
    'agency_report_generated':          '代理店控え生成',
}

function buildTimeline(auditEvents: Record<string, unknown>[]) {
    return auditEvents.slice(0, 14).map((evt, i) => ({
        no: i + 1,
        occurred_at: evt.occurred_at as string,
        category: EVENT_CATEGORY[evt.event_type as string] ?? '記録',
        label: EVENT_LABEL_JA[evt.event_type as string] ?? (evt.event_type as string),
        event_type: evt.event_type as string,
        payload_summary: evt.payload ? summarizePayload(evt.payload as Record<string, unknown>) : '',
    }))
}

function summarizePayload(payload: Record<string, unknown>): string {
    const parts: string[] = []
    if (payload.role) parts.push(`role: ${payload.role}`)
    if (payload.status) parts.push(`status: ${payload.status}`)
    if (payload.delivery_method) parts.push(`method: ${payload.delivery_method}`)
    if (payload.decision) parts.push(`decision: ${payload.decision}`)
    if (payload.source) parts.push(`src: ${payload.source}`)
    return parts.join(', ')
}
