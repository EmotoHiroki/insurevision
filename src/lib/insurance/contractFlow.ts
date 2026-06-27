// =============================================
// Phase2-b-0 (MS1): 契約フロー種別と診断基点の対応ロジック
// =============================================
// 田島 2026-06-23 の3分類を扱う。完全新規は「あるべき補償像」との差分、
// それ以外は現契約との差分で診断する、という設計判断を一箇所に集約する。

import type { ContractFlowType, DiagnosisBaseline, RunType } from '@/lib/types'

export interface ContractFlowDef {
    type: ContractFlowType
    labelJa: string
    labelEn: string
    /** 既定の診断基点 */
    diagnosisBaseline: DiagnosisBaseline
    /** 意向確認構造（intent_confirmation）の記録が必須か */
    requiresIntentConfirmation: boolean
    /** 現契約データの取込を前提とするか */
    expectsPriorContract: boolean
}

export const CONTRACT_FLOWS: readonly ContractFlowDef[] = [
    {
        type: 'new_complete',
        labelJa: '完全新規',
        labelEn: 'New (complete)',
        diagnosisBaseline: 'ideal_coverage_diff',
        requiresIntentConfirmation: true,
        expectsPriorContract: false,
    },
    {
        type: 'new_existing',
        labelJa: '新規（既存顧客）',
        labelEn: 'New (existing customer)',
        diagnosisBaseline: 'ideal_coverage_diff',
        requiresIntentConfirmation: true,
        expectsPriorContract: false,
    },
    {
        type: 'renewal',
        labelJa: '継続更改',
        labelEn: 'Renewal',
        diagnosisBaseline: 'contract_diff',
        requiresIntentConfirmation: false,
        expectsPriorContract: true,
    },
] as const

const BY_TYPE: Record<ContractFlowType, ContractFlowDef> =
    Object.fromEntries(CONTRACT_FLOWS.map(f => [f.type, f])) as Record<ContractFlowType, ContractFlowDef>

export function getContractFlow(type: ContractFlowType): ContractFlowDef {
    return BY_TYPE[type]
}

/** 契約フロー種別から既定の診断基点を返す。 */
export function diagnosisBaselineFor(type: ContractFlowType): DiagnosisBaseline {
    return BY_TYPE[type].diagnosisBaseline
}

/** 完全新規・新規既存は意向確認構造が必須。継続更改は不要。 */
export function requiresIntentConfirmation(type: ContractFlowType): boolean {
    return BY_TYPE[type].requiresIntentConfirmation
}

/**
 * 既存の run_type（new_contract / renewal）から契約フロー種別へ移行する際の
 * 既定マッピング。renewal は renewal、それ以外は既存顧客前提（安全側）。
 * 完全新規は明示選択時のみ採用する。
 */
export function contractFlowFromRunType(runType: RunType): ContractFlowType {
    return runType === 'renewal' ? 'renewal' : 'new_existing'
}
