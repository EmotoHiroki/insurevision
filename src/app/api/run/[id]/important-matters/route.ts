import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { ImportantMattersDeliveryMethod } from '@/lib/types'

// POST /api/run/[id]/important-matters
// Body: { operatorId, deliveryMethod }
export async function POST(
    request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        const { operatorId, deliveryMethod } = await request.json() as {
            operatorId: string
            deliveryMethod: ImportantMattersDeliveryMethod
        }

        if (!runId || !operatorId || !deliveryMethod) {
            return Response.json({ error: 'runId, operatorId, deliveryMethod required' }, { status: 400 })
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
            important_matters_delivered: true,
            important_matters_delivered_at: now,
            important_matters_delivery_method: deliveryMethod,
        }).eq('id', runId)
        if (upErr) return Response.json({ error: upErr.message }, { status: 500 })

        await supabase.from('audit_event').insert({
            run_id: runId,
            event_type: 'important_matters_delivery_confirmed',
            operator_id: operatorId,
            payload: { delivery_method: deliveryMethod, delivered_at: now },
        })

        return Response.json({ success: true })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
