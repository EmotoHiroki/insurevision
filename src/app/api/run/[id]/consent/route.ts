import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { ElectronicConsentStatus, ElectronicConsentMethod } from '@/lib/types'

// POST /api/run/[id]/consent
// Body: { operatorId, status, method? }
export async function POST(
    request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        const { operatorId, status, method } = await request.json() as {
            operatorId: string
            status: ElectronicConsentStatus
            method?: ElectronicConsentMethod
        }

        if (!runId || !operatorId || !status) {
            return Response.json({ error: 'runId, operatorId, status required' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()

        const { data: run, error: runErr } = await supabase
            .from('run').select('id, run_status').eq('id', runId).single()
        if (runErr || !run) return Response.json({ error: 'run not found' }, { status: 404 })
        if (run.run_status !== 'draft') {
            return Response.json({ error: 'run not editable' }, { status: 400 })
        }

        const now = new Date().toISOString()

        const updatePayload: Record<string, unknown> = {
            electronic_consent_status: status,
            electronic_consent_confirmed_at: now,
            electronic_consent_operator_id: operatorId,
        }
        if (method) updatePayload.electronic_consent_method = method

        // declined => auto-switch to paper confirmation mode
        if (status === 'declined') {
            updatePayload.paper_confirmation_status = 'pending'
            updatePayload.smartphone_conf_status = 'paper_fallback'
        }

        const { error: upErr } = await supabase.from('run').update(updatePayload).eq('id', runId)
        if (upErr) return Response.json({ error: upErr.message }, { status: 500 })

        await supabase.from('audit_event').insert({
            run_id: runId,
            event_type: 'electronic_consent_recorded',
            operator_id: operatorId,
            payload: { status, method: method ?? null, confirmed_at: now },
        })

        return Response.json({ success: true })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
