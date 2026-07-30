import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { SmartphoneConfStatus } from '@/lib/types'

// POST /api/smartphone-confirm
// Body: { token: string }
// Token encodes run_id + role -- no run_id exposed in URL
//
// b1-MS1 Stage 4: this route is called by an unauthenticated visitor (the
// customer or recruiter's own phone, no InsureVision login). Both GET and POST
// now go through SECURITY DEFINER functions granted to anon, which validate
// the token (unused, not expired) and only reveal/mutate run data through
// those functions -- direct table access remains fully revoked for anon.
// See migration 031_b1_ms1_smartphone_confirm_functions_stage4.sql.
export async function POST(request: Request) {
    try {
        const { token } = await request.json() as { token: string }
        if (!token) return Response.json({ error: 'token required' }, { status: 400 })

        const supabase = await createServerSupabaseClient()

        const { data, error } = await supabase
            .rpc('confirm_smartphone', { p_token_id: token })
            .single<{ success: boolean; status: SmartphoneConfStatus }>()

        if (error || !data) {
            const message = error?.message ?? 'confirmation failed'
            const status = message.includes('already used') ? 409
                : message.includes('expired') ? 410
                : message.includes('invalid token') ? 404
                : 400
            return Response.json({ error: message }, { status })
        }

        return Response.json({ success: true, status: data.status })
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

        const { data, error } = await supabase
            .rpc('get_smartphone_confirm_status', { p_token_id: token })
            .single<{
                is_valid: boolean
                is_used: boolean
                is_expired: boolean
                role: 'recruiter' | 'customer'
                confirmed_at: string | null
                run_id: string | null
                customer_ref: string | null
                customer_name: string | null
                recruiter_smartphone_confirmed_at: string | null
                customer_smartphone_confirmed_at: string | null
            }>()

        if (error || !data) return Response.json({ error: 'invalid token' }, { status: 404 })

        return Response.json({
            valid: data.is_valid,
            used: data.is_used,
            expired: data.is_expired,
            role: data.role,
            confirmed_at: data.confirmed_at,
            run: data.is_valid ? {
                id: data.run_id,
                customer_ref: data.customer_ref,
                customer_name: data.customer_name,
                recruiter_smartphone_confirmed_at: data.recruiter_smartphone_confirmed_at,
                customer_smartphone_confirmed_at: data.customer_smartphone_confirmed_at,
            } : null,
        })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
