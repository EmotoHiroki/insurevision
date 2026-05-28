'use client'

import { useEffect, useState, Suspense } from 'react'
import { useSearchParams } from 'next/navigation'

type Run = {
    id: string
    customer_ref: string
    customer_name?: string
    recruiter_smartphone_confirmed_at?: string
    customer_smartphone_confirmed_at?: string
}

type TokenInfo = {
    valid: boolean
    used: boolean
    expired: boolean
    role: 'recruiter' | 'customer'
    run: Run | null
}

type PageState = 'loading' | 'ready' | 'confirming' | 'done' | 'already_used' | 'error'

function SmartphoneTokenConfirmContent() {
    const searchParams = useSearchParams()
    const token = searchParams.get('token') ?? ''

    const [tokenInfo, setTokenInfo] = useState<TokenInfo | null>(null)
    const [pageState, setPageState] = useState<PageState>('loading')
    const [errorMsg, setErrorMsg] = useState('')

    useEffect(() => {
        if (!token) {
            setErrorMsg('確認URLが無効です。募集人から受け取ったURLをご使用ください。')
            setPageState('error')
            return
        }
        const load = async () => {
            const res = await fetch(`/api/smartphone-confirm?token=${encodeURIComponent(token)}`)
            if (!res.ok) {
                setErrorMsg('URLが無効か期限切れです。募集人に再送付をご依頼ください。')
                setPageState('error')
                return
            }
            const data: TokenInfo = await res.json()
            setTokenInfo(data)
            if (data.used) {
                setPageState('already_used')
            } else if (data.expired) {
                setErrorMsg('確認URLの有効期限が切れています。募集人に再発行をご依頼ください。')
                setPageState('error')
            } else if (!data.valid) {
                setErrorMsg('URLが無効です。募集人から受け取ったURLをご使用ください。')
                setPageState('error')
            } else {
                setPageState('ready')
            }
        }
        load()
    }, [token])

    const handleConfirm = async () => {
        setPageState('confirming')
        try {
            const res = await fetch('/api/smartphone-confirm', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ token }),
            })
            if (!res.ok) {
                const body = await res.json()
                throw new Error(body.error ?? '確認の送信に失敗しました')
            }
            setPageState('done')
        } catch (err: unknown) {
            setErrorMsg(err instanceof Error ? err.message : 'エラーが発生しました')
            setPageState('error')
        }
    }

    const role = tokenInfo?.role ?? 'customer'
    const run = tokenInfo?.run

    if (pageState === 'loading') {
        return (
            <div style={styles.center}>
                <p style={styles.muted}>読み込み中...</p>
            </div>
        )
    }

    if (pageState === 'already_used') {
        const confirmedAt = role === 'recruiter'
            ? tokenInfo?.run?.recruiter_smartphone_confirmed_at
            : tokenInfo?.run?.customer_smartphone_confirmed_at
        const confirmedStr = confirmedAt
            ? new Date(confirmedAt).toLocaleString('ja-JP')
            : null
        return (
            <div style={styles.center}>
                <div style={{ ...styles.card, borderColor: '#fcd34d' }}>
                    <div style={{ fontSize: 36, textAlign: 'center', marginBottom: 12 }}>✓</div>
                    <p style={{ color: '#92400e', fontWeight: 700, textAlign: 'center', marginBottom: 8 }}>確認済み</p>
                    <p style={{ fontSize: 13, color: '#78350f', textAlign: 'center', marginBottom: confirmedStr ? 8 : 0 }}>
                        {role === 'recruiter' ? '募集人確認' : 'お客様確認'}はすでに記録されています。
                    </p>
                    {confirmedStr && (
                        <p style={{ fontSize: 12, color: '#92400e', textAlign: 'center' }}>確認日時: {confirmedStr}</p>
                    )}
                </div>
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

                    <p style={{ fontSize: 11, color: '#9ca3af', textAlign: 'center', marginTop: 16 }}>
                        このURLは30分間有効です（1回限り）
                    </p>
                </div>
            </div>
        </div>
    )
}

export default function SmartphoneTokenConfirmPage() {
    return (
        <Suspense fallback={<div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'sans-serif' }}><p style={{ color: '#9ca3af' }}>読み込み中...</p></div>}>
            <SmartphoneTokenConfirmContent />
        </Suspense>
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
