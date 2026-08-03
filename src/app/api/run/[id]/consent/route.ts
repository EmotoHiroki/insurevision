import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { ElectronicConsentStatus, ElectronicConsentMethod } from '@/lib/types'

// POST /api/run/[id]/consent
// Body: { status, method? }
// operatorId は受け取らない。呼出者は record_electronic_consent() が
// auth.uid() から導出する（migration 048）。run更新とaudit_event記録は
// 同関数内の単一トランザクションで行われる。
export async function POST(
    request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        const { status, method } = await request.json() as {
            status: ElectronicConsentStatus
            method?: ElectronicConsentMethod
        }

        if (!runId || !status) {
            return Response.json({ error: 'runId, status required' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 })

        const { error } = await supabase.rpc('record_electronic_consent', {
            p_run_id: runId,
            p_status: status,
            p_method: method ?? null,
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
