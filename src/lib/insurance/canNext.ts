// =============================================
// Phase2-b-0 (MS1): canNext / canNextReason 共通ポリシー
// =============================================
// 種目横断でゲート制御を統一する基盤。各ゲートは「前進を阻む条件」を判定する
// 述語として定義し、評価結果として canNext(真偽) と理由配列を返す。
// 種目固有ゲートは、この共通フレームに gate を追加する形で b-1 以降が拡張する。

import type { ContractFlowType, CasePhase, InsuranceCategoryCode, InsuranceLineCode } from '@/lib/types'
import { requiresIntentConfirmation } from '@/lib/insurance/contractFlow'

/** ゲート評価に渡す案件コンテキスト（必要最小限。種目別に拡張可）。 */
export interface CanNextContext {
    contractFlowType: ContractFlowType | null
    casePhase: CasePhase
    insuranceCategoryCode: InsuranceCategoryCode | null
    insuranceLineCode: InsuranceLineCode | null
    /** 対象物件プロファイルが記録済みか */
    hasPropertyProfile: boolean
    /** 意向確認（推定→最終→合致）が完了しているか */
    intentConfirmed: boolean
    /** 補償重複の確認が済んでいるか */
    overlapChecked: boolean
}

export interface GateDef {
    /** 機械可読の理由コード（audit / UI 双方で使用） */
    code: string
    /** 利用者向けの理由文言 */
    reasonJa: string
    /** どのフェーズへ進む際のゲートか */
    blocksPhase: CasePhase
    /** true を返すと前進不可（ブロック） */
    isBlocked: (ctx: CanNextContext) => boolean
}

export interface CanNextResult {
    canNext: boolean
    /** ブロック中ゲートの理由コード（run.can_next_blocked_reasons に保存可） */
    blockedReasons: string[]
    /** 表示用の理由文言 */
    blockedMessages: string[]
}

// ── 種目横断の共通ゲート定義 ──────────────────────────────────────────────
export const COMMON_GATES: readonly GateDef[] = [
    {
        code: 'category_required',
        reasonJa: '種目が選択されていません',
        blocksPhase: 'in_meeting',
        isBlocked: ctx => !ctx.insuranceCategoryCode,
    },
    {
        code: 'contract_flow_required',
        reasonJa: '契約フロー種別（完全新規／新規既存／継続更改）が未選択です',
        blocksPhase: 'in_meeting',
        isBlocked: ctx => !ctx.contractFlowType,
    },
    {
        code: 'property_profile_required',
        reasonJa: '対象物件プロファイルが未記録です',
        blocksPhase: 'completed',
        isBlocked: ctx => !ctx.hasPropertyProfile,
    },
    {
        code: 'intent_confirmation_required',
        reasonJa: '意向確認（推定意向と最終意向の合致確認）が未完了です',
        blocksPhase: 'completed',
        isBlocked: ctx =>
            ctx.contractFlowType != null &&
            requiresIntentConfirmation(ctx.contractFlowType) &&
            !ctx.intentConfirmed,
    },
    {
        code: 'overlap_check_required',
        reasonJa: '補償重複の確認が未完了です',
        blocksPhase: 'completed',
        isBlocked: ctx =>
            ctx.contractFlowType != null &&
            requiresIntentConfirmation(ctx.contractFlowType) &&
            !ctx.overlapChecked,
    },
] as const

/**
 * 指定フェーズへ進めるかを共通ゲート（+ 任意の追加ゲート）で評価する。
 * targetPhase に紐づくゲートのみを判定対象とする。
 */
export function evaluateCanNext(
    ctx: CanNextContext,
    targetPhase: CasePhase,
    extraGates: readonly GateDef[] = [],
): CanNextResult {
    const gates = [...COMMON_GATES, ...extraGates].filter(g => g.blocksPhase === targetPhase)
    const blocked = gates.filter(g => g.isBlocked(ctx))
    return {
        canNext: blocked.length === 0,
        blockedReasons: blocked.map(g => g.code),
        blockedMessages: blocked.map(g => g.reasonJa),
    }
}
