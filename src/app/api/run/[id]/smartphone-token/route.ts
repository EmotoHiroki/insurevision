import { createServerSupabaseClient } from '@/lib/supabase/server'

// POST /api/run/[id]/smartphone-token
// Body: { role: 'recruiter' | 'customer' }
// Returns: { token: string, url: string, expires_at: string }
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

        const { data: run, error: runErr } = await supabase
            .from('run').select('id, run_status, meeting_scene').eq('id', runId).single()
        if (runErr || !run) return Response.json({ error: 'run not found' }, { status: 404 })
        if (run.run_status !== 'draft') {
            return Response.json({ error: 'run not editable' }, { status: 400 })
        }

        const { data: token, error: tokenErr } = await supabase
            .from('smartphone_confirm_token')
            .insert({ run_id: runId, role })
            .select('id, expires_at')
            .single()

        if (tokenErr || !token) {
            return Response.json({ error: 'failed to create token' }, { status: 500 })
        }

        const origin = new URL(request.url).origin
        const url = `${origin}/run/smartphone?token=${token.id}`

        return Response.json({ token: token.id, url, expires_at: token.expires_at })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}
