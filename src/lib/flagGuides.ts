// =============================================
// Recruiter Guidance — flag_key → message map
// M1 v4.1 Section 8
// =============================================

export const MISSING_GUIDE_MESSAGES: Record<string, { ja: string; en: string }> = {
    option_a: {
        ja: '比較項目Aが証券に記載されていません。証券の特約欄・別紙明細をご確認ください。',
        en: 'Option A is missing from the policy. Check the special clause or appendix.',
    },
    option_b: {
        ja: '比較項目Bが確認できません。特約の付帯状況を顧客に直接確認してください。',
        en: 'Option B is unconfirmed. Verify rider status directly with the customer.',
    },
    option_c_flag: {
        ja: '比較項目Cの記載が見つかりません。申込書控えまたは証券の追加ページをご確認ください。',
        en: 'Option C not found. Check the application copy or additional policy pages.',
    },
    coverage_amount: {
        ja: '補償金額の記載がありません。証券の補償金額欄を確認し、手動で入力してください。',
        en: 'Coverage amount is missing. Check the policy coverage section and enter manually.',
    },
    expiry_date: {
        ja: '契約満期日が未入力です。証券の契約期間欄からご確認ください。',
        en: 'Expiry date is missing. Check the contract period section in the policy.',
    },
    insurer_code: {
        ja: '保険会社コードが未設定です。証券のヘッダー部分から保険会社名を確認してください。',
        en: 'Insurer code is not set. Check the insurer name in the policy header.',
    },
}

export const UNCERTAIN_GUIDE_MESSAGES: Record<string, { ja: string; en: string }> = {
    option_a: {
        ja: '比較項目Aの内容が不確かです（Fail-Closed）。顧客に「この特約は含まれていますか？」と直接確認し、回答内容をメモしてください。',
        en: 'Option A is uncertain (Fail-Closed). Ask the customer directly: "Is this rider included?" and note their response.',
    },
    option_c_flag: {
        ja: '比較項目Cの情報が確認できません（Fail-Closed）。世帯内の別契約にこの特約が含まれていないかもご確認ください。',
        en: 'Option C is uncertain (Fail-Closed). Also check whether other household contracts include this rider.',
    },
    coverage_amount: {
        ja: '補償金額が不明瞭です（Fail-Closed）。証券を再確認するか、保険会社に問い合わせてください。',
        en: 'Coverage amount is unclear (Fail-Closed). Re-check the policy or contact the insurer.',
    },
    completeness_score: {
        ja: 'この候補の完成度が閾値未満です（Fail-Closed）。completeness_exception_note を入力するか、情報を補完してから再度ご確認ください。',
        en: 'This candidate is below the completeness threshold (Fail-Closed). Enter a completeness exception note or supplement the information.',
    },
}

/**
 * Returns the guide message for a given flag_key.
 * Falls back to a generic message if the key is not in the map.
 */
export function getMissingGuideMessage(flagKey: string, locale: 'ja' | 'en'): string {
    return (
        MISSING_GUIDE_MESSAGES[flagKey]?.[locale] ??
        (locale === 'ja'
            ? `「${flagKey}」が未設定です。証券または顧客にご確認ください。`
            : `"${flagKey}" is missing. Check the policy or confirm with the customer.`)
    )
}

export function getUncertainGuideMessage(flagKey: string, locale: 'ja' | 'en'): string {
    return (
        UNCERTAIN_GUIDE_MESSAGES[flagKey]?.[locale] ??
        (locale === 'ja'
            ? `「${flagKey}」が不確かです（Fail-Closed）。顧客に直接ご確認ください。`
            : `"${flagKey}" is uncertain (Fail-Closed). Confirm directly with the customer.`)
    )
}
