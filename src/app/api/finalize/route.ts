import { createServerSupabaseClient } from '@/lib/supabase/server'

// ─────────────────────────────────────────────
// POST /api/finalize
// Body: {
//   runId: string,
//   consentFlags: { comparison_result: boolean, important_matters: boolean, personal_info: boolean },
// }
// operatorId は受け取らない。確定者は finalize_run() が auth.uid() から
// 導出する。同意3種のaudit_eventも finalize_run() の内部で、確定処理と
// 同一トランザクションで記録される（migration 048）。
//
// 田島様2026-08-04ご指摘5: exceptionRouteはクライアントから受け取らず、
// finalize_run()内の判定（v_customer_decision <> 'compare'）と同じ式で
// サーバー側のrun.customer_decisionから導出する。事前チェック（このAPI
// ルート内）とDB側の最終判定が異なる値を見て食い違う余地をなくす。
// ─────────────────────────────────────────────
export async function POST(request: Request) {
    try {
        const { runId, consentFlags } = await request.json()

        if (!runId) {
            return Response.json({ error: 'runId is required' }, { status: 400 })
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

        // customer_decision は exceptionRoute の導出元であり、NULLだと
        // `null !== 'compare'` が true になって「例外ルート」と解釈される。
        // その結果、compare_presented_at と post_record の2つの検査が
        // まるごとスキップされ、証跡登録とStorageアップロードという副作用を
        // 実行したうえで、最後に finalize_run() 側で拒否されていた。
        // DB側は許容値をホワイトリストで検査しているので、同じ基準を
        // 副作用より前に適用する（NULLを最も緩い分岐へ倒さない）。
        const VALID_DECISIONS = ['compare', 'renewal_no_change', 'information_refused', 'comparison_waived']
        if (!run.customer_decision || !VALID_DECISIONS.includes(run.customer_decision)) {
            return Response.json(
                { error: '顧客の意向（customer_decision）が未設定または不正な値です' },
                { status: 422 },
            )
        }

        const exceptionRoute = run.customer_decision !== 'compare'

        const { data: snapshot } = await supabase
            .from('snapshot').select('*').eq('run_id', runId).maybeSingle()

        // Fail-Closed: snapshot must exist and have no unresolved items.
        // 田島様2026-08-04ご指摘5: snapshot不存在を合格扱いしていた（if(snapshot && ...)
        // はsnapshotがnullの場合まるごとスキップされる）。finalize_run()側は
        // snapshot 0件を明示的に拒否しており、このAPIルートの事前チェックだけが
        // 緩い状態だった。
        if (!snapshot) {
            return Response.json({ error: 'snapshot not found' }, { status: 422 })
        }
        if (snapshot.unresolved_items.length > 0) {
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

        // 田島様2026-08-06ご指摘6: meeting_scene・recording_mode はDB側
        // （finalize_run）では確定の必須条件だが、API側はこれらの不足を
        // 証跡登録・Storageアップロードより前に拒否していなかった。この結果、
        // 最終的にDBで拒否されるとしても、失敗が確定している案件の証跡登録と
        // アップロードが先に実行され得た（副作用が先に走る）。
        // これはDB側で是正した「NULLの場合に検査自体がスキップされる」構図と
        // 同型であり、直下の important_matters の検査も
        // `run.meeting_scene &&` を条件にしていたため、meeting_sceneがNULLだと
        // 検査ごとスキップされていた。画面・API・DBを同一基準に揃える。
        if (!run.meeting_scene) {
            return Response.json({ error: '面談シーン（meeting_scene）が未設定です' }, { status: 422 })
        }
        if (!run.recording_mode) {
            return Response.json({ error: '記録方式（recording_mode）が未設定です' }, { status: 422 })
        }
        if (!run.important_matters_delivered) {
            return Response.json({ error: '重要事項説明書の交付確認が完了していません' }, { status: 422 })
        }

        // ── 証跡本文をDB側で組み立てさせる ──
        // 田島様2026-08-06ご指摘: migration 056までは、アプリが組み立てた本文を
        // save_run_proof()へ渡していた。この関数は空でなければ任意のテキストを
        // 受け付けていたため、利用者が自分のrunに対して事実と異なる内容の証跡を
        // 登録・アップロードして確定することが可能であった（保存物の同一性は
        // 保証していたが、内容がrunの実態を反映していることは保証していなかった）。
        // migration 057以降、本文はDBがrun・snapshotから組み立てる。アプリは
        // 本文にもオブジェクトキーにも関与せず、戻り値をそのまま使用する。
        const { data: proofRows, error: proofErr } = await supabase.rpc('save_run_proof', {
            p_run_id: runId,
            p_consent_comparison_result: consentFlags.comparison_result ?? false,
            p_consent_important_matters: consentFlags.important_matters ?? false,
            p_consent_personal_info: consentFlags.personal_info ?? false,
        })
        const proof = Array.isArray(proofRows) ? proofRows[0] : proofRows
        if (proofErr || !proof?.object_key || !proof?.payload || !proof?.sha256) {
            return Response.json(
                { error: `proof registration failed: ${proofErr?.message ?? 'no proof returned'}` },
                { status: 500 },
            )
        }
        const pdfObjectKey = proof.object_key as string
        const pdfJson = proof.payload as string
        const pdfSha256 = proof.sha256 as string

        // ── Upload proof to Storage before finalizing ──
        // authenticatedクライアントでアップロードすることで、storage.objectsの
        // RLSを経由させる。migration 057で当該ポリシーにrun_statusの許可リストを
        // 追加したため、確定後・アーカイブ後・保留中は上書き自体が拒否される
        // （確定済み証跡の差し替えによる無効化を防ぐ）。
        // finalize_run()は、保存された実体のサイズとeTag（Storageサービスが
        // 実バイト列から書き込む値。呼出し元は偽装できない）を、DB上の本文と
        // 突き合わせて内容一致を検証する。
        const { error: uploadErr } = await supabase.storage
            .from('proofs')
            .upload(pdfObjectKey, pdfJson, {
                contentType: 'application/json',
                upsert: true,
            })
        if (uploadErr) {
            return Response.json({ error: `proof upload failed: ${uploadErr.message}` }, { status: 500 })
        }

        // ── Atomic finalize via RPC ──
        // b1-MS1 Stage 3: finalize_run now derives the caller's operator identity
        // from auth.uid() internally (rather than trusting the p_operator_id
        // argument) and re-validates all finalize conditions server-side, so it
        // can no longer be bypassed by calling the RPC directly. See migration
        // 030_b1_ms1_finalize_run_stage3_remediation.sql.
        // 同意3種は finalize_run() の引数として渡し、確定処理と同一
        // トランザクション内で記録させる。従来は comparison_result のみを
        // 渡し、残る2種をRPC呼出しの後に別途INSERTしていたため、確定は
        // 成功したが同意証跡だけ失敗する状態を作りうる構造だった
        // （migration 048で是正）。
        const { error: rpcErr } = await supabase.rpc('finalize_run', {
            p_run_id: runId,
            p_pdf_object_key: pdfObjectKey,
            p_pdf_sha256: pdfSha256,
            p_consent_comparison_result: consentFlags.comparison_result ?? false,
            p_consent_important_matters: consentFlags.important_matters ?? false,
            p_consent_personal_info: consentFlags.personal_info ?? false,
        })
        if (rpcErr) return Response.json({ error: rpcErr.message }, { status: 500 })

        return Response.json({ success: true, pdfObjectKey, pdfSha256 })
    } catch (err: unknown) {
        console.error('[finalize] unexpected error:', err)
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}

// 証跡本文の組み立ては migration 057 で DB 側（save_run_proof）へ移した。
// アプリが本文を組み立てて渡す実装は、任意の内容を登録できてしまうため廃止した。
