'use client'

import { useEffect, useState } from 'react'
import { useParams, useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import type { Run } from '@/lib/types'

type ConfRole = 'recruiter' | 'customer'
type PageState = 'loading' | 'ready' | 'confirming' | 'done' | 'error'

export default function SmartphoneConfirmPage() {
    const params = useParams()
    const runId = params.id as string
    const searchParams = useSearchParams()
    const role = (searchParams.get('role') ?? 'customer') as ConfRole

    const [run, setRun] = useState<Run | null>(null)
    const [pageState, setPageState] = useState<PageState>('loading')
    const [errorMsg, setErrorMsg] = useState('')

    useEffect(() => {
        const load = async () => {
            const supabase = createClient()
            const { data, error } = await supabase
                .from('run')
                .select('id, customer_ref, customer_name, smartphone_conf_status, recruiter_smartphone_confirmed_at, customer_smartphone_confirmed_at')
                .eq('id', runId)
                .single()
            if (error || !data) {
                setErrorMsg('案件が見つかりません / Run not found')
                setPageState('error')
                return
            }
            setRun(data as Run)
            // Already confirmed by this role?
            if (role === 'recruiter' && data.recruiter_smartphone_confirmed_at) {
                setPageState('done')
            } else if (role === 'customer' && data.customer_smartphone_confirmed_at) {
                setPageState('done')
            } else {
                setPageState('ready')
            }
        }
        load()
    }, [runId, role])

    const handleConfirm = async () => {
        setPageState('confirming')
        try {
            // For smartphone page, we use the run_id as operatorId placeholder (Phase2-a)
            // In production this would use a proper token/session
            const res = await fetch(`/api/run/${runId}/smartphone-confirm`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ operatorId: runId, role }),
            })
            if (!res.ok) {
                const body = await res.json()
                throw new Error(body.error ?? 'Confirmation failed')
            }
            setPageState('done')
        } catch (err: unknown) {
            setErrorMsg(err instanceof Error ? err.message : 'Error')
            setPageState('error')
        }
    }

    const isJa = true // smartphone page is always Japanese

    if (pageState === 'loading') {
        return (
            <div style={styles.center}>
                <p style={styles.muted}>読み込み中...</p>
            </div>
        )
    }

    if (pageState === 'error') {
        return (
            <div style={styles.center}>
                <div style={{ ...styles.card, borderColor: '#fca5a5' }}>
                    <p style={{ color: '#dc2626', fontWeight: 600, marginBottom: 8 }}>エラー</p>
                    <p style={{ fontSize: 14, color: '#7f1d1d' }}>{errorMsg}</p>
                </div>
            </div>
        )
    }

    if (pageState === 'done') {
        return (
            <div style={styles.center}>
                <div style={styles.card}>
                    <div style={{ fontSize: 48, textAlign: 'center', marginBottom: 16 }}>✓</div>
                    <h1 style={{ fontSize: 18, fontWeight: 700, textAlign: 'center', marginBottom: 8 }}>
                        確認完了
                    </h1>
                    <p style={{ fontSize: 13, color: '#6b7280', textAlign: 'center' }}>
                        {role === 'recruiter'
                            ? '募集人確認が完了しました。このページを閉じてください。'
                            : 'お客様確認が完了しました。このページを閉じてください。'}
                    </p>
                </div>
            </div>
        )
    }

    return (
        <div style={styles.page}>
            <header style={styles.header}>
                <span style={{ fontSize: 14, fontWeight: 700 }}>安心見える化™</span>
            </header>

            <div style={styles.content}>
                <div style={styles.card}>
                    <h1 style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
                        {role === 'recruiter' ? '募集人確認' : 'お客様確認'}
                    </h1>
                    <p style={{ fontSize: 13, color: '#6b7280', marginBottom: 20 }}>
                        {role === 'recruiter'
                            ? '重要事項説明書の内容を確認し、説明完了を記録してください。'
                            : '重要事項説明書の内容を確認し、受領を記録してください。'}
                    </p>

                    {run && (
                        <div style={styles.infoBox}>
                            <div style={styles.infoRow}>
                                <span style={styles.infoLabel}>顧客参照ID</span>
                                <span style={styles.infoValue}>{run.customer_ref}</span>
                            </div>
                            {run.customer_name && (
                                <div style={styles.infoRow}>
                                    <span style={styles.infoLabel}>お客様名</span>
                                    <span style={styles.infoValue}>{run.customer_name}</span>
                                </div>
                            )}
                        </div>
                    )}

                    <div style={{ background: '#eff6ff', borderRadius: 8, padding: 14, marginBottom: 20, fontSize: 13, color: '#1e40af' }}>
                        {role === 'recruiter'
                            ? '重要事項説明書の内容を十分にご説明いただきましたか？'
                            : '重要事項説明書の内容を確認いただけましたか？'}
                    </div>

                    <button
                        onClick={handleConfirm}
                        disabled={pageState === 'confirming'}
                        style={styles.confirmBtn}
                    >
                        {pageState === 'confirming' ? '送信中...' : (
                            role === 'recruiter' ? '説明完了を記録する' : '受領を確認する'
                        )}
                    </button>
                </div>
            </div>
        </div>
    )
}

const styles = {
    page: {
        minHeight: '100vh',
        background: '#f9fafb',
        fontFamily: '-apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif',
    } as React.CSSProperties,
    header: {
        background: '#1d4ed8',
        color: 'white',
        padding: '14px 20px',
    } as React.CSSProperties,
    content: {
        padding: 20,
        maxWidth: 420,
        margin: '0 auto',
        paddingTop: 32,
    } as React.CSSProperties,
    center: {
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 20,
        fontFamily: '-apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif',
    } as React.CSSProperties,
    card: {
        background: 'white',
        borderRadius: 12,
        padding: 24,
        boxShadow: '0 2px 12px rgba(0,0,0,0.08)',
        border: '1px solid #e5e7eb',
        width: '100%',
        maxWidth: 380,
    } as React.CSSProperties,
    infoBox: {
        background: '#f9fafb',
        borderRadius: 8,
        padding: 12,
        marginBottom: 16,
    } as React.CSSProperties,
    infoRow: {
        display: 'flex',
        justifyContent: 'space-between',
        fontSize: 13,
        padding: '4px 0',
    } as React.CSSProperties,
    infoLabel: {
        color: '#6b7280',
    } as React.CSSProperties,
    infoValue: {
        fontWeight: 600,
        color: '#111827',
    } as React.CSSProperties,
    confirmBtn: {
        width: '100%',
        padding: '14px',
        background: '#1d4ed8',
        color: 'white',
        border: 'none',
        borderRadius: 8,
        fontSize: 15,
        fontWeight: 700,
        cursor: 'pointer',
    } as React.CSSProperties,
    muted: {
        color: '#9ca3af',
        fontSize: 14,
    } as React.CSSProperties,
}
