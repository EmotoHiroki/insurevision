'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useLocale } from '@/lib/locale-context'
import { LuShield, LuMail, LuLock, LuGlobe } from 'react-icons/lu'

export default function LoginPage() {
    const router = useRouter()
    const { t, toggleLocale, locale } = useLocale()
    const [email, setEmail] = useState('')
    const [password, setPassword] = useState('')
    const [error, setError] = useState('')
    const [loading, setLoading] = useState(false)

    const handleLogin = async (e: React.FormEvent) => {
        e.preventDefault()
        setError('')
        setLoading(true)

        try {
            const supabase = createClient()
            const { error: err } = await supabase.auth.signInWithPassword({
                email: email.trim(),
                password,
            })
            if (err) throw err
            router.push('/dashboard')
            router.refresh()
        } catch (err: unknown) {
            setError(err instanceof Error ? err.message : t('loginError'))
        } finally {
            setLoading(false)
        }
    }

    return (
        <div style={{
            minHeight: '100vh',
            background: 'linear-gradient(135deg, #0d1642 0%, #1a237e 40%, #3949ab 100%)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            padding: '20px',
        }}>
            {/* Language toggle */}
            <button
                onClick={toggleLocale}
                style={{
                    position: 'absolute',
                    top: 24,
                    right: 24,
                    background: 'rgba(255,255,255,0.1)',
                    border: '1px solid rgba(255,255,255,0.2)',
                    color: 'rgba(255,255,255,0.8)',
                    padding: '8px 14px',
                    borderRadius: '8px',
                    cursor: 'pointer',
                    display: 'flex',
                    alignItems: 'center',
                    gap: '6px',
                    fontSize: '13px',
                    backdropFilter: 'blur(8px)',
                }}
            >
                <LuGlobe size={14} />
                {locale === 'ja' ? 'EN' : 'JA'}
            </button>

            <div className="animate-fade-in" style={{
                width: '100%',
                maxWidth: 440,
                background: 'white',
                borderRadius: 16,
                padding: '48px 40px',
                boxShadow: '0 20px 60px rgba(0,0,0,0.2)',
            }}>
                {/* Logo */}
                <div style={{ textAlign: 'center', marginBottom: 32 }}>
                    <div style={{
                        width: 64,
                        height: 64,
                        background: 'linear-gradient(135deg, #1a237e, #00bcd4)',
                        borderRadius: 14,
                        display: 'inline-flex',
                        alignItems: 'center',
                        justifyContent: 'center',
                        marginBottom: 16,
                    }}>
                        <LuShield size={32} color="white" />
                    </div>
                    <h1 style={{ fontSize: 26, fontWeight: 700, color: '#0d1642', margin: 0 }}>
                        {t('appTitle')}
                    </h1>
                    <p style={{ fontSize: 14, color: '#6b7280', marginTop: 4 }}>
                        {t('appSubtitle')}
                    </p>
                </div>

                {/* Welcome */}
                <div style={{ marginBottom: 28 }}>
                    <h2 style={{ fontSize: 18, fontWeight: 600, color: '#1a1a2e', margin: 0 }}>
                        {t('welcomeBack')}
                    </h2>
                    <p style={{ fontSize: 13, color: '#6b7280', margin: '4px 0 0' }}>
                        {t('loginSubtitle')}
                    </p>
                </div>

                <form onSubmit={handleLogin}>
                    <div style={{ marginBottom: 18 }}>
                        <label className="form-label">{t('email')}</label>
                        <div style={{ position: 'relative' }}>
                            <LuMail size={16} color="#9ca3af" style={{
                                position: 'absolute', left: 14, top: '50%', transform: 'translateY(-50%)'
                            }} />
                            <input
                                type="email"
                                className="form-input"
                                style={{ paddingLeft: 40 }}
                                value={email}
                                onChange={e => setEmail(e.target.value)}
                                placeholder="operator@agency.co.jp"
                                required
                            />
                        </div>
                    </div>

                    <div style={{ marginBottom: 18 }}>
                        <label className="form-label">{t('password')}</label>
                        <div style={{ position: 'relative' }}>
                            <LuLock size={16} color="#9ca3af" style={{
                                position: 'absolute', left: 14, top: '50%', transform: 'translateY(-50%)'
                            }} />
                            <input
                                type="password"
                                className="form-input"
                                style={{ paddingLeft: 40 }}
                                value={password}
                                onChange={e => setPassword(e.target.value)}
                                placeholder="••••••••"
                                required
                            />
                        </div>
                    </div>

                    {error && (
                        <div style={{
                            background: 'rgba(198,40,40,0.08)',
                            color: '#c62828',
                            padding: '10px 14px',
                            borderRadius: 8,
                            fontSize: 13,
                            marginBottom: 16,
                        }}>
                            {error}
                        </div>
                    )}

                    <button
                        type="submit"
                        className="btn-primary"
                        disabled={loading}
                        style={{
                            width: '100%',
                            justifyContent: 'center',
                            padding: '12px 24px',
                            fontSize: 15,
                            marginTop: 8,
                        }}
                    >
                        {loading ? (
                            <span className="animate-pulse-soft">{t('loading')}</span>
                        ) : (
                            t('login')
                        )}
                    </button>
                </form>
            </div>
        </div>
    )
}
