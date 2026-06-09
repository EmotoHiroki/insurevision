import { createServerSupabaseClient } from '@/lib/supabase/server'

// POST /api/run/[id]/plan-selection
// Body: { operatorId, recommendedCandidateId?, decidedCandidateId?, planDiffReason? }
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
    try {
        const { id: runId } = await params
        const body = await request.json() as {
            operatorId: string
            recommendedCandidateId?: string | null
            decidedCandidateId?: string | null
            planDiffReason?: string | null
        }

        const supabase = await createServerSupabaseClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 })

        const { data: run } = await supabase.from('run').select('id, run_status').eq('id', runId).single()
        if (!run) return Response.json({ error: 'run not found' }, { status: 404 })
        if (run.run_status !== 'draft' && run.run_status !== 'post_record_pending') {
            return Response.json({ error: 'run not editable' }, { status: 400 })
        }

        const now = new Date().toISOString()
        const updates: Record<string, unknown> = {}
        const events: { event_type: string; payload: Record<string, unknown> }[] = []

        if ('recommendedCandidateId' in body) {
            updates.recommended_candidate_id = body.recommendedCandidateId ?? null
            events.push({ event_type: 'recommended_plan_set', payload: { candidate_id: body.recommendedCandidateId } })
        }
        if ('decidedCandidateId' in body) {
            updates.decided_candidate_id = body.decidedCandidateId ?? null
            events.push({ event_type: 'decided_plan_set', payload: { candidate_id: body.decidedCandidateId } })
        }
        if ('planDiffReason' in body) {
            updates.plan_diff_reason = body.planDiffReason ?? null
            updates.plan_diff_reason_recorded_at = body.planDiffReason ? now : null
            events.push({ event_type: 'plan_diff_reason_recorded', payload: { reason: body.planDiffReason, recorded_at: now } })
        }

        if (Object.keys(updates).length > 0) {
            const { error: upErr } = await supabase.from('run').update(updates).eq('id', runId)
            if (upErr) return Response.json({ error: upErr.message }, { status: 500 })
        }

        for (const evt of events) {
            await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: evt.event_type,
                operator_id: body.operatorId,
                payload: evt.payload,
            })
        }

        return Response.json({ success: true })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
