import { createServerSupabaseClient } from '@/lib/supabase/server'

// POST /api/run/[id]/paper-confirm
// Body: {}（operatorId は受け取らない）
// 呼出者は record_paper_confirmation() が auth.uid() から導出する
// （migration 048）。run更新とaudit_event記録は単一トランザクション。
export async function POST(
    _request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        if (!runId) {
            return Response.json({ error: 'runId required' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 })

        const { error } = await supabase.rpc('record_paper_confirmation', {
            p_run_id: runId,
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
