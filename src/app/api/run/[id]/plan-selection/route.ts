import { createServerSupabaseClient } from '@/lib/supabase/server'

// POST /api/run/[id]/plan-selection
// Body: { recommendedCandidateId?, decidedCandidateId?, planDiffReason? }
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
    try {
        const { id: runId } = await params
        const body = await request.json() as {
            recommendedCandidateId?: string | null
            decidedCandidateId?: string | null
            planDiffReason?: string | null
        }

        const supabase = await createServerSupabaseClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 })

        const { error } = await supabase.rpc('record_plan_selection', {
            p_run_id: runId,
            p_recommended_candidate_id: body.recommendedCandidateId ?? null,
            p_decided_candidate_id: body.decidedCandidateId ?? null,
            p_plan_diff_reason: body.planDiffReason ?? null,
            p_set_recommended: 'recommendedCandidateId' in body,
            p_set_decided: 'decidedCandidateId' in body,
            p_set_plan_diff_reason: 'planDiffReason' in body,
        })
        if (error) return Response.json({ error: error.message }, { status: 400 })

        return Response.json({ success: true })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
