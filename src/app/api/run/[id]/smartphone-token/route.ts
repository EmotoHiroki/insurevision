import { createServerSupabaseClient } from '@/lib/supabase/server'

// POST /api/run/[id]/smartphone-token
// Body: { role: 'recruiter' | 'customer' }
// Returns: { token: string, url: string, expires_at: string }
//
// b1-MS1 Stage 4: token issuance now goes through issue_smartphone_confirm_token,
// a SECURITY DEFINER function that derives the caller's operator identity from
// auth.uid() and verifies agency ownership of the run, rather than relying on
// direct table INSERT (which 016 revoked for anon/authenticated). See migration
// 031_b1_ms1_smartphone_confirm_functions_stage4.sql.
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
            .rpc('issue_smartphone_confirm_token', { p_run_id: runId, p_role: role })
            .single<{ token_id: string; expires_at: string }>()

        if (error || !data) {
            return Response.json({ error: error?.message ?? 'failed to create token' }, { status: 400 })
        }

        const origin = new URL(request.url).origin
        const url = `${origin}/run/smartphone?token=${data.token_id}`

        return Response.json({ token: data.token_id, url, expires_at: data.expires_at })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
