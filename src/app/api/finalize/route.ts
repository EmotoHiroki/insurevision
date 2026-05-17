import { createServerSupabaseClient } from '@/lib/supabase/server'
import type { Run, Snapshot, MinimalProofPdfStub } from '@/lib/types'

// ─────────────────────────────────────────────
// POST /api/finalize
// Body: {
//   runId: string,
//   operatorId: string,
//   consentFlags: { comparison_result: boolean, important_matters: boolean, personal_info: boolean },
//   exceptionRoute: boolean,
// }
// ─────────────────────────────────────────────
export async function POST(request: Request) {
    try {
        const { runId, operatorId, consentFlags, exceptionRoute } = await request.json()

        if (!runId || !operatorId) {
            return Response.json({ error: 'runId and operatorId are required' }, { status: 400 })
        }

        const supabase = await createServerSupabaseClient()

        // ── Validation ──
        const { data: run, error: runErr } = await supabase
            .from('run').select('*').eq('id', runId).single()
        if (runErr || !run) return Response.json({ error: 'run not found' }, { status: 404 })

        // G-21: allow 'draft' or 'post_record_pending' (post_record flow finalizes from post_record_pending)
        if (run.run_status !== 'draft' && run.run_status !== 'post_record_pending') {
            return Response.json({ error: 'already finalized' }, { status: 400 })
        }

        const { data: snapshot } = await supabase
            .from('snapshot').select('*').eq('run_id', runId).maybeSingle()

        // Fail-Closed: unresolved_items must be empty
        if (snapshot && snapshot.unresolved_items.length > 0) {
            return Response.json(
                { error: 'unresolved_items', items: snapshot.unresolved_items },
                { status: 422 }
            )
        }

        // M2 Spec 5: insurer_list_presented must be recorded for all paths
        const { data: insurerListEvent } = await supabase
            .from('audit_event')
            .select('id')
            .eq('run_id', runId)
            .eq('event_type', 'insurer_list_presented')
            .maybeSingle()
        if (!insurerListEvent) {
            return Response.json({ error: 'insurer_list_presented not recorded' }, { status: 422 })
        }

        // G-21: post_record mode requires phase2 completion before finalize
        // Skipped for exception routes (non-compare decisions have nothing to post-record)
        if (!exceptionRoute && run.recording_mode === 'post_record' && run.post_record_status !== 'phase2_done') {
            return Response.json({ error: '事後記録のフェーズ2が完了していません' }, { status: 422 })
        }

        // Normal path: compare_presented_at must be set
        if (!exceptionRoute && !run.compare_presented_at) {
            return Response.json({ error: 'compare_presented_at not set' }, { status: 422 })
        }

        // Phase2-a: important_matters_delivered gate (only when meeting_scene is set)
        if (run.meeting_scene && !run.important_matters_delivered) {
            return Response.json({ error: '重要事項説明書の交付確認が完了していません' }, { status: 422 })
        }

        // ── Build minimal proof stub ──
        const pdfStub = buildMinimalProofStub(run as Run, snapshot as Snapshot | null, consentFlags)
        const pdfJson = JSON.stringify(pdfStub)

        // SHA-256 using Web Crypto API (available in edge/Node environments)
        const encoder = new TextEncoder()
        const data = encoder.encode(pdfJson)
        const hashBuffer = await crypto.subtle.digest('SHA-256', data)
        const hashArray = Array.from(new Uint8Array(hashBuffer))
        const pdfSha256 = hashArray.map(b => b.toString(16).padStart(2, '0')).join('')
        const pdfObjectKey = `runs/${runId}/proof.json`

        // ── Atomic finalize via RPC ──
        const { error: rpcErr } = await supabase.rpc('finalize_run', {
            p_run_id: runId,
            p_pdf_object_key: pdfObjectKey,
            p_pdf_sha256: pdfSha256,
            p_operator_id: operatorId,
            p_consent_comparison_result: consentFlags.comparison_result ?? false,
        })
        if (rpcErr) return Response.json({ error: rpcErr.message }, { status: 500 })

        // ── Additional consent events (outside transaction) ──
        const additionalEvents = []
        if (consentFlags.important_matters) {
            additionalEvents.push({
                run_id: runId,
                event_type: 'consent_important_matters' as const,
                operator_id: operatorId,
                payload: { obtained_at: new Date().toISOString() },
            })
        }
        if (consentFlags.personal_info) {
            additionalEvents.push({
                run_id: runId,
                event_type: 'consent_personal_info' as const,
                operator_id: operatorId,
                payload: { obtained_at: new Date().toISOString() },
            })
        }
        if (additionalEvents.length > 0) {
            await supabase.from('audit_event').insert(additionalEvents)
        }

        return Response.json({ success: true, pdfObjectKey, pdfSha256 })
    } catch (err: unknown) {
        console.error('[finalize] unexpected error:', err)
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}

// ─────────────────────────────────────────────
// buildMinimalProofStub — pure function, no DB calls
// ─────────────────────────────────────────────
function buildMinimalProofStub(
    run: Run,
    snapshot: Snapshot | null,
    consentFlags: { comparison_result: boolean; important_matters: boolean; personal_info: boolean }
): MinimalProofPdfStub {
    const stub: MinimalProofPdfStub = {
        run_id: run.id,
        customer_ref: run.customer_ref,
        operator_name: run.operator_id,   // Phase 2: resolve to actual name
        generated_at: new Date().toISOString(),
        customer_decision: run.customer_decision!,
        decision_reason: run.customer_intent_memo ?? '',
        insurer_list_presented: true,   // always true: auto-recorded at Step2→3 for all paths
    }

    // comparison_waived path: include consent flags
    if (run.customer_decision === 'comparison_waived') {
        stub.consent_important_matters = consentFlags.important_matters
        stub.consent_personal_info = consentFlags.personal_info
    }

    // compare path: include comparison_result consent
    if (run.customer_decision === 'compare') {
        stub.consent_comparison_result = consentFlags.comparison_result
    }

    // Snapshot data for traceability
    if (snapshot) {
        Object.assign(stub, {
            confirmed_items: snapshot.confirmed_items,
            supplemented_items: snapshot.supplemented_items,
            core_logic_version: snapshot.core_logic_version,
        })
    }

    return stub
}
