import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { SmartphoneConfStatus } from '@/lib/types'

// POST /api/run/[id]/smartphone-confirm
// Body: { operatorId, role: 'recruiter' | 'customer' }
export async function POST(
    request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        const { operatorId, role } = await request.json() as {
            operatorId: string
            role: 'recruiter' | 'customer'
        }

        if (!runId || !operatorId || !role) {
            return Response.json({ error: 'runId, operatorId, role required' }, { status: 400 })
        }
        if (role !== 'recruiter' && role !== 'customer') {
            return Response.json({ error: 'role must be recruiter or customer' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()

        const { data: run, error: runErr } = await supabase
            .from('run').select('id, run_status, smartphone_conf_status').eq('id', runId).single()
        if (runErr || !run) return Response.json({ error: 'run not found' }, { status: 404 })
        if (run.run_status !== 'draft') {
            return Response.json({ error: 'run not editable' }, { status: 400 })
        }

        const now = new Date().toISOString()

        let newStatus: SmartphoneConfStatus
        let updatePayload: Record<string, unknown>
        let eventType: 'recruiter_smartphone_confirmed' | 'customer_smartphone_confirmed'

        if (role === 'recruiter') {
            newStatus = 'recruiter_confirmed'
            updatePayload = { smartphone_conf_status: newStatus, recruiter_smartphone_confirmed_at: now }
            eventType = 'recruiter_smartphone_confirmed'
        } else {
            newStatus = 'customer_confirmed'
            updatePayload = { smartphone_conf_status: newStatus, customer_smartphone_confirmed_at: now }
            eventType = 'customer_smartphone_confirmed'
        }

        const { error: upErr } = await supabase.from('run').update(updatePayload).eq('id', runId)
        if (upErr) return Response.json({ error: upErr.message }, { status: 500 })

        await supabase.from('audit_event').insert({
            run_id: runId,
            event_type: eventType,
            operator_id: operatorId,
            payload: { role, confirmed_at: now },
        })

        return Response.json({ success: true, status: newStatus })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
