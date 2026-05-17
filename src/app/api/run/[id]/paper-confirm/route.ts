import { createServerSupabaseClient } from '@/lib/supabase/server'

// POST /api/run/[id]/paper-confirm
// Body: { operatorId }
export async function POST(
    request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        const { operatorId } = await request.json() as { operatorId: string }

        if (!runId || !operatorId) {
            return Response.json({ error: 'runId and operatorId required' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()

        const { data: run, error: runErr } = await supabase
            .from('run').select('id, run_status').eq('id', runId).single()
        if (runErr || !run) return Response.json({ error: 'run not found' }, { status: 404 })
        if (run.run_status !== 'draft') {
            return Response.json({ error: 'run not editable' }, { status: 400 })
        }

        const now = new Date().toISOString()

        const { error: upErr } = await supabase.from('run').update({
            paper_confirmation_status: 'completed',
            paper_confirmation_completed_at: now,
        }).eq('id', runId)
        if (upErr) return Response.json({ error: upErr.message }, { status: 500 })

        await supabase.from('audit_event').insert({
            run_id: runId,
            event_type: 'paper_confirmation_completed',
            operator_id: operatorId,
            payload: { completed_at: now },
        })

        return Response.json({ success: true })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
