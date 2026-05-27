import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { SmartphoneConfStatus } from '@/lib/types'

// POST /api/smartphone-confirm
// Body: { token: string }
// Token encodes run_id + role -- no run_id exposed in URL
export async function POST(request: Request) {
    try {
        const { token } = await request.json() as { token: string }
        if (!token) return Response.json({ error: 'token required' }, { status: 400 })

        const supabase = await createServerSupabaseClient()

        const { data: tok, error: tokErr } = await supabase
            .from('smartphone_confirm_token')
            .select('id, run_id, role, expires_at, used_at')
            .eq('id', token)
            .single()

        if (tokErr || !tok) return Response.json({ error: 'invalid token' }, { status: 404 })
        if (tok.used_at) return Response.json({ error: 'token already used' }, { status: 409 })
        if (new Date(tok.expires_at) < new Date()) {
            return Response.json({ error: 'token expired' }, { status: 410 })
        }

        const { data: run, error: runErr } = await supabase
            .from('run').select('id, run_status, operator_id').eq('id', tok.run_id).single()
        if (runErr || !run) return Response.json({ error: 'run not found' }, { status: 404 })
        if (run.run_status !== 'draft') {
            return Response.json({ error: 'run not editable' }, { status: 400 })
        }

        const now = new Date().toISOString()
        const role = tok.role as 'recruiter' | 'customer'

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

        const { error: upErr } = await supabase.from('run').update(updatePayload).eq('id', tok.run_id)
        if (upErr) return Response.json({ error: upErr.message }, { status: 500 })

        // Mark token as used
        await supabase.from('smartphone_confirm_token').update({ used_at: now }).eq('id', token)

        await supabase.from('audit_event').insert({
            run_id: tok.run_id,
            event_type: eventType,
            operator_id: run.operator_id,
            payload: { role, confirmed_at: now, token_id: token, source: 'smartphone_token' },
        })

        return Response.json({ success: true, status: newStatus })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}

// GET /api/smartphone-confirm?token=<uuid>
// Returns run info needed to render the confirmation page
export async function GET(request: Request) {
    try {
        const { searchParams } = new URL(request.url)
        const token = searchParams.get('token')
        if (!token) return Response.json({ error: 'token required' }, { status: 400 })

        const supabase = await createServerSupabaseClient()

        const { data: tok, error: tokErr } = await supabase
            .from('smartphone_confirm_token')
            .select('id, run_id, role, expires_at, used_at')
            .eq('id', token)
            .single()

        if (tokErr || !tok) return Response.json({ error: 'invalid token' }, { status: 404 })

        const { data: run } = await supabase
            .from('run')
            .select('id, customer_ref, customer_name, recruiter_smartphone_confirmed_at, customer_smartphone_confirmed_at')
            .eq('id', tok.run_id)
            .single()

        return Response.json({
            valid: !tok.used_at && new Date(tok.expires_at) >= new Date(),
            used: !!tok.used_at,
            expired: new Date(tok.expires_at) < new Date(),
            role: tok.role,
            run: run ?? null,
        })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
