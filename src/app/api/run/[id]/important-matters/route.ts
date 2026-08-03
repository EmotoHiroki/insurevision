import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { ImportantMattersDeliveryMethod } from '@/lib/types'

// POST /api/run/[id]/important-matters
// Body: { deliveryMethod }（operatorId は受け取らない）
// 呼出者は record_important_matters_delivery() が auth.uid() から導出する
// （migration 048）。run更新とaudit_event記録は単一トランザクション。
export async function POST(
    request: Request,
    { params }: { params: Promise<{ id: string }> }
) {
    try {
        const { id: runId } = await params
        const { deliveryMethod } = await request.json() as {
            deliveryMethod: ImportantMattersDeliveryMethod
        }

        if (!runId || !deliveryMethod) {
            return Response.json({ error: 'runId, deliveryMethod required' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()
        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 })

        const { error } = await supabase.rpc('record_important_matters_delivery', {
            p_run_id: runId,
            p_delivery_method: deliveryMethod,
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
