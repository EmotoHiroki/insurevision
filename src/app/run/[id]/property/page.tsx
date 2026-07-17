'use client'

// =============================================
// Phase2-b-1 (MS1): 火災 対象物件プロファイル 入力骨格
// =============================================
// 個人/企業を1機能内で切り替える統合方針（田島 2026-07-07正式化案 §1）に基づく入力スケルトン。
// b1-MS1範囲: 入力・保存・水災等地の静的参照まで。診断ロジック・比較・canNext接続はb1-MS2。
// 未回答/はい/いいえの三値管理（田島 2026-07-16指摘反映）。既定値による補完は行わない。

import { useEffect, useState } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { ArrowLeft, Shield } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import {
    OWNERSHIP_TYPES, ownershipTypeLabel, floodRiskLabel,
    emptyPropertyAttributes, isPropertyProfileComplete, isIndividualAttributes,
    deriveScheduleReference,
    type OwnershipType, type PropertyAttributes,
    type IndividualPropertyAttributes, type CorporatePropertyAttributes,
} from '@/lib/insurance/property'
import type { CustomerType, Run, FloodZoneMaster } from '@/lib/types'

export default function PropertyProfilePage() {
    const params = useParams()
    const router = useRouter()
    const runId = params.id as string
    const { locale } = useLocale()

    const [run, setRun] = useState<Run | null>(null)
    const [zones, setZones] = useState<FloodZoneMaster[]>([])
    const [municipalityCode, setMunicipalityCode] = useState('')
    const [attrs, setAttrs] = useState<PropertyAttributes | null>(null)
    const [loading, setLoading] = useState(true)
    const [saving, setSaving] = useState(false)
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)

    useEffect(() => {
        const supabase = createClient()
        Promise.all([
            supabase.from('run').select('*').eq('id', runId).single(),
            supabase.from('flood_zone_master').select('*').order('prefecture').order('municipality_name'),
            supabase.from('property_profile').select('*').eq('run_id', runId).eq('line_code', 'fire').maybeSingle(),
        ]).then(([runRes, zoneRes, profileRes]) => {
            if (runRes.data) {
                setRun(runRes.data as Run)
                setAttrs(
                    (profileRes.data?.attributes as PropertyAttributes) ??
                    emptyPropertyAttributes(runRes.data.customer_type as CustomerType),
                )
                setMunicipalityCode((profileRes.data?.municipality_code as string) ?? '')
            }
            if (zoneRes.data) setZones(zoneRes.data as FloodZoneMaster[])
            setLoading(false)
        })
    }, [runId])

    const selectedZone = zones.find(z => z.municipality_code === municipalityCode)
    const customerType = run?.customer_type as CustomerType | undefined

    const save = async () => {
        if (!run || !attrs || !customerType) return
        setSaving(true)
        setError('')
        try {
            const supabase = createClient()
            const { data: { user } } = await supabase.auth.getUser()
            if (!user) throw new Error('Not authenticated')
            const { data: op } = await supabase.from('operator').select('id').eq('auth_user_id', user.id).single()
            if (!op) throw new Error('Operator not found')

            const { error: upsertErr } = await supabase.from('property_profile').upsert({
                run_id: runId,
                line_code: 'fire',
                municipality_code: municipalityCode || null,
                attributes: attrs,
            }, { onConflict: 'run_id,line_code' })
            if (upsertErr) throw upsertErr

            const { error: eventErr } = await supabase.from('audit_event').insert({
                run_id: runId,
                event_type: 'property_profile_recorded',
                operator_id: op.id,
                payload: {
                    line_code: 'fire',
                    customer_type: customerType,
                    municipality_code: municipalityCode || null,
                    flood_grade: selectedZone?.flood_grade ?? null,
                    complete: isPropertyProfileComplete(customerType, attrs),
                },
            })
            if (eventErr) throw eventErr

            setSaved(true)
        } catch (err: unknown) {
            setError(err instanceof Error ? err.message : 'An error occurred')
        } finally {
            setSaving(false)
        }
    }

    if (loading) return <div className="p-8 text-sm text-gray-500">{locale === 'ja' ? '読み込み中...' : 'Loading...'}</div>
    if (!run || !attrs || !customerType) return <div className="p-8 text-sm text-red-600">{locale === 'ja' ? '案件が見つかりません' : 'Run not found'}</div>

    return (
        <div className="min-h-screen bg-gray-50">
            <header className="bg-blue-700 text-white h-14 flex items-center gap-3 px-6 shadow-md">
                <button onClick={() => router.push(`/run/${runId}`)} className="bg-white/10 hover:bg-white/20 border-0 text-white p-2 rounded cursor-pointer">
                    <ArrowLeft size={18} />
                </button>
                <Shield size={18} />
                <span className="font-semibold">
                    {locale === 'ja' ? '対象物件プロファイル（火災）' : 'Property Profile (Fire)'}
                </span>
            </header>

            <div className="max-w-2xl mx-auto p-8 space-y-5">
                <div className="p-4 bg-amber-50 border border-amber-200 rounded-lg text-xs text-amber-800">
                    {locale === 'ja'
                        ? 'b1-MS1 入力骨格版です。診断・比較への接続はb1-MS2で行います。'
                        : 'b1-MS1 input skeleton. Diagnosis/comparison wiring is done in b1-MS2.'}
                </div>

                <div className="p-6 bg-white rounded-xl border border-gray-200 shadow-sm space-y-5">
                    <h2 className="text-base font-semibold text-gray-800">
                        {locale === 'ja' ? '所在地（水災等地参照）' : 'Location (flood zone reference)'}
                    </h2>
                    <div>
                        <label className="form-label">{locale === 'ja' ? '市区町村' : 'Municipality'}</label>
                        <select
                            className="form-input"
                            value={municipalityCode}
                            onChange={e => setMunicipalityCode(e.target.value)}
                        >
                            <option value="">{locale === 'ja' ? '選択してください' : 'Select...'}</option>
                            {zones.map(z => (
                                <option key={z.municipality_code} value={z.municipality_code}>
                                    {z.prefecture} {z.municipality_name}
                                </option>
                            ))}
                        </select>
                        {selectedZone && (
                            <p className="text-xs text-gray-500 mt-1">
                                {locale === 'ja' ? '水災等地: ' : 'Flood zone: '}
                                <span className="font-medium">{floodRiskLabel(selectedZone.flood_grade, locale)}</span>
                                {' '}({selectedZone.source})
                            </p>
                        )}
                    </div>
                </div>

                {customerType === 'individual' && isIndividualAttributes(attrs) && (
                    <IndividualForm attrs={attrs} onChange={setAttrs} locale={locale} />
                )}
                {customerType === 'corporate' && !isIndividualAttributes(attrs) && (
                    <CorporateForm attrs={attrs} onChange={setAttrs} locale={locale} />
                )}

                {error && <div className="px-4 py-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700">{error}</div>}
                {saved && <div className="px-4 py-3 bg-green-50 border border-green-200 rounded-lg text-sm text-green-700">
                    {locale === 'ja' ? '保存しました' : 'Saved'}
                </div>}

                <button onClick={save} disabled={saving} className="btn-primary w-full">
                    {saving ? (locale === 'ja' ? '保存中...' : 'Saving...') : (locale === 'ja' ? '保存' : 'Save')}
                </button>
            </div>
        </div>
    )
}

// ─────────────────────────────────────────────
// TriToggle — 未回答/はい/いいえ の三値トグル
// null=未回答 を既定値による補完なしで明示的に区別する（田島 2026-07-16指摘）
// ─────────────────────────────────────────────
function TriToggle({ label, value, onChange, locale }: {
    label: string
    value: boolean | null
    onChange: (v: boolean | null) => void
    locale: 'ja' | 'en'
}) {
    const options: { v: boolean | null; labelJa: string; labelEn: string }[] = [
        { v: null, labelJa: '未回答', labelEn: 'Unanswered' },
        { v: true, labelJa: 'はい', labelEn: 'Yes' },
        { v: false, labelJa: 'いいえ', labelEn: 'No' },
    ]
    return (
        <div>
            <label className="form-label">{label}</label>
            <div className="grid grid-cols-3 gap-2 mt-2">
                {options.map(o => (
                    <label
                        key={String(o.v)}
                        className={`radio-card cursor-pointer text-center text-sm ${value === o.v ? 'ring-2 ring-blue-500' : ''}`}
                    >
                        <input
                            type="radio"
                            className="sr-only"
                            checked={value === o.v}
                            onChange={() => onChange(o.v)}
                        />
                        <span className="font-medium">{locale === 'ja' ? o.labelJa : o.labelEn}</span>
                    </label>
                ))}
            </div>
        </div>
    )
}

function IndividualForm({ attrs, onChange, locale }: {
    attrs: IndividualPropertyAttributes
    onChange: (a: PropertyAttributes) => void
    locale: 'ja' | 'en'
}) {
    const set = <K extends keyof IndividualPropertyAttributes>(key: K, value: IndividualPropertyAttributes[K]) =>
        onChange({ ...attrs, [key]: value })

    return (
        <div className="p-6 bg-white rounded-xl border border-gray-200 shadow-sm space-y-5">
            <h2 className="text-base font-semibold text-gray-800">
                {locale === 'ja' ? '個人物件情報' : 'Property Details (Individual)'}
            </h2>

            <div>
                <label className="form-label">{locale === 'ja' ? '所有形態' : 'Ownership'}</label>
                <div className="grid grid-cols-3 gap-2 mt-2">
                    {OWNERSHIP_TYPES.map(o => (
                        <label key={o.code} className={`radio-card cursor-pointer text-center ${attrs.ownership_type === o.code ? 'ring-2 ring-blue-500' : ''}`}>
                            <input type="radio" name="ownershipType" className="sr-only"
                                checked={attrs.ownership_type === o.code}
                                onChange={() => set('ownership_type', o.code as OwnershipType)} />
                            <span className="text-sm font-medium">{ownershipTypeLabel(o.code, locale)}</span>
                        </label>
                    ))}
                </div>
                {attrs.ownership_type === null && (
                    <p className="text-xs text-gray-400 mt-1">{locale === 'ja' ? '未回答' : 'Unanswered'}</p>
                )}
            </div>

            <div>
                <label className="form-label">{locale === 'ja' ? '構造' : 'Structure'}</label>
                <input type="text" className="form-input" value={attrs.building_structure ?? ''}
                    onChange={e => set('building_structure', e.target.value || null)}
                    placeholder={locale === 'ja' ? '例: 木造、耐火' : 'e.g. Wood, Fire-resistant'} />
            </div>

            <div>
                <label className="form-label">{locale === 'ja' ? '延床面積（㎡）' : 'Floor area (sqm)'}</label>
                <input type="number" className="form-input" value={attrs.floor_area_sqm ?? ''}
                    onChange={e => set('floor_area_sqm', e.target.value ? Number(e.target.value) : null)} />
            </div>

            <TriToggle
                label={locale === 'ja' ? '家財を含む' : 'Includes household goods'}
                value={attrs.has_household_goods}
                onChange={v => set('has_household_goods', v)}
                locale={locale}
            />

            <TriToggle
                label={locale === 'ja' ? '地震保険を付帯' : 'Earthquake insurance rider'}
                value={attrs.earthquake_insurance}
                onChange={v => set('earthquake_insurance', v)}
                locale={locale}
            />

            {attrs.ownership_type === 'rental' && (
                <div className="pt-3 border-t border-gray-100 space-y-4">
                    <p className="text-xs font-medium text-gray-500">{locale === 'ja' ? '賃貸のみ' : 'Rental only'}</p>
                    <TriToggle
                        label={locale === 'ja' ? '借家人賠償' : 'Renter liability'}
                        value={attrs.renter_liability}
                        onChange={v => set('renter_liability', v)}
                        locale={locale}
                    />
                    <TriToggle
                        label={locale === 'ja' ? '個人賠償' : 'Personal liability'}
                        value={attrs.personal_liability}
                        onChange={v => set('personal_liability', v)}
                        locale={locale}
                    />
                </div>
            )}
        </div>
    )
}

function CorporateForm({ attrs, onChange, locale }: {
    attrs: CorporatePropertyAttributes
    onChange: (a: PropertyAttributes) => void
    locale: 'ja' | 'en'
}) {
    const set = <K extends keyof CorporatePropertyAttributes>(key: K, value: CorporatePropertyAttributes[K]) =>
        onChange({ ...attrs, [key]: value })

    return (
        <div className="p-6 bg-white rounded-xl border border-gray-200 shadow-sm space-y-5">
            <h2 className="text-base font-semibold text-gray-800">
                {locale === 'ja' ? '企業物件情報（複数拠点）' : 'Property Details (Corporate, multi-site)'}
            </h2>

            <div>
                <label className="form-label">{locale === 'ja' ? '物件数' : 'Property count'}</label>
                <input type="number" min={1} className="form-input" value={attrs.property_count ?? ''}
                    placeholder={locale === 'ja' ? '未回答' : 'Unanswered'}
                    onChange={e => {
                        const count = e.target.value ? Math.max(1, Number(e.target.value)) : null
                        onChange({ ...attrs, property_count: count, schedule_reference: deriveScheduleReference(count) })
                    }} />
            </div>

            <div>
                <label className="form-label">{locale === 'ja' ? '構造（共通）' : 'Structure (common)'}</label>
                <input type="text" className="form-input" value={attrs.building_structure ?? ''}
                    onChange={e => set('building_structure', e.target.value || null)} />
            </div>

            <div>
                <label className="form-label">{locale === 'ja' ? '合計延床面積（㎡・任意）' : 'Total floor area (sqm, optional)'}</label>
                <input type="number" className="form-input" value={attrs.floor_area_sqm_total ?? ''}
                    onChange={e => set('floor_area_sqm_total', e.target.value ? Number(e.target.value) : null)} />
            </div>

            {attrs.property_count !== null && attrs.property_count > 1 && (
                <div className="pt-3 border-t border-gray-100 space-y-4">
                    <p className="text-xs text-gray-500">
                        {locale === 'ja'
                            ? '支払限度額・免責金額等は「別紙明細のとおり」とし、本ツール内では入力しません。複数物件のため、別紙明細参照は前提として扱います（選択不要）。'
                            : 'Payment limits / deductibles follow the separate itemized schedule and are not entered here. Since this is multi-property, schedule reference is treated as a given (no selection needed).'}
                    </p>
                    <TriToggle
                        label={locale === 'ja' ? '別紙明細書の受領・了知を確認済み' : 'Schedule received & acknowledged'}
                        value={attrs.schedule_acknowledged}
                        onChange={v => set('schedule_acknowledged', v)}
                        locale={locale}
                    />
                </div>
            )}
        </div>
    )
}
