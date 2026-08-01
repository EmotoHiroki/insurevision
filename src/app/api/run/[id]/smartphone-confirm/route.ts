import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { SmartphoneConfStatus } from '@/lib/types'

// POST /api/run/[id]/smartphone-confirm
// Body: { role: 'recruiter' | 'customer' }
//
// b1-MS1 #48/#49 (2026-08-01): previously trusted a client-supplied
// operatorId for the audit_event write, and directly UPDATEd run +
// INSERTed audit_event from the route. Migration 039 (audit_event
// recording-path protection) now blocks direct authenticated inserts of
// recruiter_smartphone_confirmed/customer_smartphone_confirmed, so this
// route must go through the dedicated function. It also derives the
// operator from auth.uid() server-side rather than trusting the request
// body. See migration 040_b1_ms1_smartphone_manual_confirmation_function.sql.
export async function POST(
    request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        const { role } = await request.json() as { role: 'recruiter' | 'customer' }

        if (!runId || !role) {
            return Response.json({ error: 'runId and role required' }, { status: 400 })
        }
        if (role !== 'recruiter' && role !== 'customer') {
            return Response.json({ error: 'role must be recruiter or customer' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()

        const { data, error } = await supabase
            .rpc('record_smartphone_manual_confirmation', { p_run_id: runId, p_role: role })
            .single<{ success: boolean; status: SmartphoneConfStatus }>()

        if (error || !data) {
            return Response.json({ error: error?.message ?? 'confirmation failed' }, { status: 400 })
        }

        return Response.json({ success: true, status: data.status })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
