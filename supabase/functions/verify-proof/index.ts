// ============================================================================
// verify-proof
//
// 田島様2026-08-06ご指摘2への対応。
// Storage上の実ファイル（proof.json）をサーバー側で取得し、その実バイト列から
// SHA-256を算出して、検証済みの値としてDBへ記録する。
//
// 【なぜアプリ側ではなくここで行うか】
//   ハッシュの算出を呼出し元（ブラウザ）に任せると、呼出し元は任意の値を
//   申告できてしまう。本関数は service_role でStorageから実体を読み出し、
//   読み出したバイト列そのものからハッシュを算出するため、
//   呼出し元は算出結果に関与できない。
//
// 【呼出し元の権限確認】
//   service_role キーは本関数の内部だけで使用し、外部へは出さない。
//   呼出し元については、渡されたユーザーJWTで run を参照できるかどうかを
//   RLS経由で確認する。参照できない run に対しては検証を行わない。
//   これにより、他代理店の run に対して検証を走らせることはできない。
//
// 【記録先】
//   public.record_verified_proof_hash() を service_role で呼び出す。
//   同関数は current_user が service_role であることを検査し、
//   算出値がDB上の本文のSHA-256と一致しない場合は記録せずに拒否する。
//
// 【差し替えの検知】
//   ダウンロード時点の storage.objects.version をあわせて記録する。
//   version はアップロードのたびに変わるため、検証後に実体が差し替えられた
//   場合は finalize_run() の照合で必ず食い違い、確定が拒否される。
//
// 呼出し方:
//   POST /functions/v1/verify-proof
//   Authorization: Bearer <ユーザーのアクセストークン>
//   { "runId": "<uuid>" }
// ============================================================================

import { createClient } from 'jsr:@supabase/supabase-js@2'

const BUCKET = 'proofs'

interface VerifyRequest {
    runId?: string
}

function json(body: unknown, status: number): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' },
    })
}

/** 実バイト列から SHA-256 を算出し、小文字16進で返す。 */
async function sha256Hex(bytes: Uint8Array): Promise<string> {
    const digest = await crypto.subtle.digest('SHA-256', bytes)
    return Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('')
}

Deno.serve(async (req: Request) => {
    if (req.method !== 'POST') {
        return json({ error: 'POST only' }, 405)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
    if (!supabaseUrl || !serviceKey || !anonKey) {
        return json({ error: 'server is not configured' }, 500)
    }

    // ── 呼出し元の認証 ──
    const authHeader = req.headers.get('Authorization') ?? ''
    if (!authHeader.toLowerCase().startsWith('bearer ')) {
        return json({ error: 'authorization required' }, 401)
    }

    let body: VerifyRequest
    try {
        body = await req.json()
    } catch {
        return json({ error: 'invalid json body' }, 400)
    }
    const runId = body.runId
    if (!runId || !/^[0-9a-f-]{36}$/i.test(runId)) {
        return json({ error: 'runId is required' }, 400)
    }

    // 呼出し元のJWTで動作するクライアント。RLSが適用される。
    const asCaller = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authHeader } },
        auth: { persistSession: false },
    })

    // 呼出し元がこの run を参照できることを確認する。
    // 参照できない場合、その run は呼出し元の代理店のものではない。
    const { data: visibleRun, error: runErr } = await asCaller
        .from('run')
        .select('id, run_status')
        .eq('id', runId)
        .maybeSingle()
    if (runErr) {
        return json({ error: `run lookup failed: ${runErr.message}` }, 500)
    }
    if (!visibleRun) {
        // 存在しない場合と、権限がなく見えない場合を区別しない。
        return json({ error: 'run not found' }, 404)
    }
    if (visibleRun.run_status !== 'draft' && visibleRun.run_status !== 'post_record_pending') {
        return json(
            { error: `run is ${visibleRun.run_status}; verification is only meaningful before finalization` },
            409,
        )
    }

    // ── ここから service_role ──
    const asService = createClient(supabaseUrl, serviceKey, {
        auth: { persistSession: false },
    })

    const objectKey = `runs/${runId}/proof.json`

    // Storage上の実体をダウンロードする。ここで得たバイト列だけを信頼する。
    const { data: blob, error: dlErr } = await asService.storage
        .from(BUCKET)
        .download(objectKey)
    if (dlErr || !blob) {
        return json(
            { error: `proof object not found in storage: ${dlErr?.message ?? 'no body'}` },
            404,
        )
    }

    const bytes = new Uint8Array(await blob.arrayBuffer())
    const verifiedSha256 = await sha256Hex(bytes)

    // 検証結果を記録する。
    //
    // 実体の版（storage.objects.version）は、あえてこちらからは渡さない。
    // ダウンロードと版の取得を別々に行うと、その間に実体が差し替えられた場合に
    // 「古いバイト列のハッシュ」と「新しい実体の版」を組にして記録してしまう。
    // 記録関数側が storage.objects 行をロックしたうえで版を読み取り、
    // その時点の実体がDB上の本文と一致することまで確認する。
    //
    // 算出値がDB上の本文のSHA-256と一致しない場合、この呼出しはDB側で
    // 拒否され、検証結果は記録されない（確定もできない）。
    const { data: recordedVersion, error: recErr } = await asService.rpc(
        'record_verified_proof_hash',
        {
            p_run_id: runId,
            p_verified_sha256: verifiedSha256,
            p_byte_size: bytes.byteLength,
        },
    )
    if (recErr) {
        return json({ error: recErr.message, verifiedSha256 }, 422)
    }

    return json(
        {
            verified: true,
            runId,
            objectKey,
            verifiedSha256,
            byteSize: bytes.byteLength,
            objectVersion: recordedVersion,
        },
        200,
    )
})
