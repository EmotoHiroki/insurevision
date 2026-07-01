import { createServerSupabaseClient } from '@/lib/supabase/server'

// GET /api/run/[id]/csv-export
// Returns CSV skeleton for the run (A-3: field definitions + output format)
// Full import processing and complete mapping = Phase2-b
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
    try {
        const { id: runId } = await params
        const supabase = await createServerSupabaseClient()

        const { data: { user } } = await supabase.auth.getUser()
        if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 })

        const { data: run } = await supabase.from('run').select('*').eq('id', runId).single()
        if (!run) return Response.json({ error: 'run not found' }, { status: 404 })

        const { data: candidates } = await supabase
            .from('candidate').select('*').eq('run_id', runId).order('slot_no')

        const { data: auditEvents } = await supabase
            .from('audit_event').select('*').eq('run_id', runId).order('occurred_at', { ascending: true })

        // Build CSV rows
        // Common fields (種目横断共通) first, then auto-specific fields
        const rows = buildCsvRows(run, candidates || [], auditEvents || [])

        const csv = toCsv(rows)

        return new Response(csv, {
            headers: {
                'Content-Type': 'text/csv; charset=utf-8',
                'Content-Disposition': `attachment; filename="run_${run.customer_ref}_export.csv"`,
            },
        })
    } catch (err: unknown) {
        return Response.json(
            { error: err instanceof Error ? err.message : 'Internal server error' },
            { status: 500 }
        )
    }
}

// 種目表示名マップ（insurance_line テーブルと同期）
const LINE_LABEL_JA: Record<string, string> = {
    auto: '自動車保険',
    fire: '火災保険',
}

// ── CSV field definitions (A-3: 骨格) ────────────────────────────────────────
// Structure: section | field_name | value | note
// Designed to be extensible: plan rows are dynamic (not hardcoded to 4)
function buildCsvRows(
    run: Record<string, unknown>,
    candidates: Record<string, unknown>[],
    auditEvents: Record<string, unknown>[]
): string[][] {
    const rows: string[][] = [
        ['セクション', 'フィールド名', '値', '備考'],
        // ── 共通: 案件基本情報 ──
        ['案件基本情報', 'run_id',           String(run.id ?? ''), ''],
        ['案件基本情報', 'customer_ref',     String(run.customer_ref ?? ''), '顧客参照ID'],
        ['案件基本情報', 'customer_name',    String(run.customer_name ?? ''), ''],
        ['案件基本情報', 'customer_type',    String(run.customer_type ?? ''), 'individual/corporate'],
        ['案件基本情報', 'run_type',         String(run.run_type ?? ''), 'new_contract/renewal'],
        ['案件基本情報', 'insurance_line_code',  String(run.insurance_line_code ?? ''), '種目コード（b0-MS1以降）'],
        ['案件基本情報', 'insurance_line_label', LINE_LABEL_JA[String(run.insurance_line_code ?? '')] ?? String(run.insurance_line_code ?? ''), '種目表示名'],
        ['案件基本情報', 'insurance_category_code', String(run.insurance_category_code ?? ''), '上位5分類コード'],
        ['案件基本情報', 'product_line',      String(run.product_line ?? ''), '旧フィールド（b-1以降は非推奨）'],
        ['案件基本情報', 'meeting_scene',    String(run.meeting_scene ?? ''), '面談シーン'],
        ['案件基本情報', 'run_status',       String(run.run_status ?? ''), ''],
        ['案件基本情報', 'created_at',       String(run.created_at ?? ''), ''],
        ['案件基本情報', 'finalized_at',     String(run.finalized_at ?? ''), ''],
        // ── 共通: 意向・同意 ──
        ['意向・同意', 'customer_decision',              String(run.customer_decision ?? ''), ''],
        ['意向・同意', 'electronic_consent_status',     String(run.electronic_consent_status ?? ''), ''],
        ['意向・同意', 'electronic_consent_confirmed_at', String(run.electronic_consent_confirmed_at ?? ''), ''],
        ['意向・同意', 'important_matters_delivered',    String(run.important_matters_delivered ?? ''), ''],
        ['意向・同意', 'important_matters_delivery_method', String(run.important_matters_delivery_method ?? ''), ''],
        ['意向・同意', 'important_matters_delivered_at', String(run.important_matters_delivered_at ?? ''), ''],
        // ── 共通: スマホ確認 ──
        ['スマホ確認', 'smartphone_conf_status',             String(run.smartphone_conf_status ?? ''), ''],
        ['スマホ確認', 'recruiter_smartphone_confirmed_at',   String(run.recruiter_smartphone_confirmed_at ?? ''), ''],
        ['スマホ確認', 'customer_smartphone_confirmed_at',    String(run.customer_smartphone_confirmed_at ?? ''), ''],
        ['スマホ確認', 'paper_confirmation_status',           String(run.paper_confirmation_status ?? ''), ''],
        ['スマホ確認', 'paper_confirmation_completed_at',     String(run.paper_confirmation_completed_at ?? ''), ''],
        // ── 共通: 推奨・決定プラン + 差異理由 ──
        ['プラン選択', 'recommended_candidate_id', String(run.recommended_candidate_id ?? ''), '募集人推奨プランID'],
        ['プラン選択', 'decided_candidate_id',     String(run.decided_candidate_id ?? ''), 'お客様決定プランID'],
        ['プラン選択', 'plan_diff_reason',          String(run.plan_diff_reason ?? ''), '差異理由（代理店控えのみ）'],
        ['プラン選択', 'plan_diff_reason_recorded_at', String(run.plan_diff_reason_recorded_at ?? ''), ''],
    ]

    // ── 比較候補（プラン数可変・ハードコードなし） ──
    for (const c of candidates) {
        const prefix = `plan_${c.slot_no}`
        rows.push(['比較プラン', `${prefix}.id`,           String(c.id ?? ''), ''])
        rows.push(['比較プラン', `${prefix}.role`,         String(c.role ?? ''), 'prior/same_conditions/recommended_N'])
        rows.push(['比較プラン', `${prefix}.insurer_name`, String(c.insurer_name ?? ''), ''])
        rows.push(['比較プラン', `${prefix}.product_name`, String(c.product_name ?? ''), ''])
        rows.push(['比較プラン', `${prefix}.annual_premium`, String(c.annual_premium ?? ''), ''])
        rows.push(['比較プラン', `${prefix}.coverage_status`, String(c.coverage_status ?? ''), 'full/partial/none'])
        rows.push(['比較プラン', `${prefix}.status`,       String(c.status ?? ''), 'active/excluded'])
        rows.push(['比較プラン', `${prefix}.exclusion_reason_code`, String(c.exclusion_reason_code ?? ''), ''])
    }

    // ── 証跡サマリー（監査用） ──
    rows.push(['証跡', 'audit_event_count', String(auditEvents.length), ''])
    const finalized = auditEvents.find(e => e.event_type === 'run_finalized')
    rows.push(['証跡', 'finalized_event_at', finalized ? String(finalized.occurred_at) : '', ''])
    const lastEvent = auditEvents[auditEvents.length - 1]
    rows.push(['証跡', 'last_event_at', lastEvent ? String(lastEvent.occurred_at) : '', ''])
    rows.push(['証跡', 'last_event_type', lastEvent ? String(lastEvent.event_type) : '', ''])

    // ── 注記 (A-3 scope) ──
    rows.push(['注記', 'scope', 'MS3骨格: フィールド定義・出力形式のみ', '全項目完全マッピング・取込処理はPhase2-b'])
    rows.push(['注記', 'insurance_line_note', 'insurance_line_code が正式な種目フィールド（b0-MS1以降）', 'product_lineは旧フィールドで非推奨'])

    return rows
}

function toCsv(rows: string[][]): string {
    return '﻿' + rows.map(row =>
        row.map(cell => {
            const s = String(cell)
            if (s.includes(',') || s.includes('"') || s.includes('\n')) {
                return '"' + s.replace(/"/g, '""') + '"'
            }
            return s
        }).join(',')
    ).join('\r\n')
}
