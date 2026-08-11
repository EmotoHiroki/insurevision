/**
 * 保留・再開の純粋ロジック（DB・HTTPには接続しない）
 *
 * 田島様2026-08-10ご指摘②③および2026-08-11ご判断への対応。
 *
 *  ②  保留種別・保留メモ・保留日時をすべて必須とする。
 *  ③  DB更新の error だけでなく、競合・RLS不一致・対象行なしによる
 *      「更新0件」も成功扱いしない。
 *  判断 保留は draft からのみ可能とする（post_record_pending からは不可）。
 *
 * 画面はここで定義した判定のみを用い、成功トーストの表示可否を決める。
 * DB側の強制は migration 070（遷移許可リスト・保留3項目必須）と
 * migration 071（保留・再開の監査記録）で行う。二重で担保する。
 */

import type { RunStatus } from '@/lib/types'

/** 保留操作を開始できる run_status。draft のみ。 */
export const SUSPENDABLE_STATUSES: readonly RunStatus[] = ['draft'] as const

/** 再開操作を開始できる run_status。suspended のみ。 */
export const RESUMABLE_STATUSES: readonly RunStatus[] = ['suspended'] as const

export type SuspensionType = 'condition_adjustment' | 'mid_session'

export const SUSPENSION_TYPES: readonly SuspensionType[] = [
    'condition_adjustment',
    'mid_session',
] as const

export function canSuspend(runStatus: RunStatus): boolean {
    return SUSPENDABLE_STATUSES.includes(runStatus)
}

export function canResume(runStatus: RunStatus): boolean {
    return RESUMABLE_STATUSES.includes(runStatus)
}

export type SuspendInput = {
    runStatus: RunStatus
    suspensionType: string | null | undefined
    pendingNote: string | null | undefined
}

export type ValidationResult =
    | { ok: true }
    | { ok: false; reason: 'not_suspendable' | 'invalid_type' | 'note_required' }

/**
 * 保留の入力検証。3項目すべてが揃っていなければ拒否する。
 * 保留日時は送信時に生成するため、ここでは種別とメモを検証する。
 */
export function validateSuspendInput(input: SuspendInput): ValidationResult {
    if (!canSuspend(input.runStatus)) {
        return { ok: false, reason: 'not_suspendable' }
    }
    if (
        !input.suspensionType ||
        !SUSPENSION_TYPES.includes(input.suspensionType as SuspensionType)
    ) {
        return { ok: false, reason: 'invalid_type' }
    }
    if (!input.pendingNote || input.pendingNote.trim() === '') {
        return { ok: false, reason: 'note_required' }
    }
    return { ok: true }
}

export type UpdateOutcome =
    | { ok: true }
    | { ok: false; reason: 'error' | 'no_rows' }

/**
 * DB更新結果の解釈。
 *
 * ご指摘③の核心: error が無くても affectedRows が0なら失敗として扱う。
 * 0件は「対象行が無い」「RLSで見えない」「他の操作と競合して条件から外れた」
 * のいずれかであり、いずれも操作は成立していない。
 */
export function interpretUpdateResult(params: {
    error: unknown
    affectedRows: number | null | undefined
}): UpdateOutcome {
    if (params.error) return { ok: false, reason: 'error' }
    if (params.affectedRows == null || params.affectedRows === 0) {
        return { ok: false, reason: 'no_rows' }
    }
    return { ok: true }
}

/** 成功トーストを表示してよいか。失敗時は必ず false。 */
export function shouldShowSuccess(outcome: UpdateOutcome): boolean {
    return outcome.ok
}
